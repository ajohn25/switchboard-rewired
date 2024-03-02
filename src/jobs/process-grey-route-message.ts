import isNil from 'lodash/isNil';

import { PoolOrPoolClient } from '../db';
import {
  outbound_message_stages,
  phone_number_requests,
} from '../lib/db-types';
import { insert } from '../lib/inserter';
import {
  chooseAreaCodeForSendingLocation,
  DecisionStage,
  getFromNumberMapping,
  hoursBetweenDates,
  ProcessMessagePayload,
  ProcessMessagePayloadSchema,
} from '../lib/process-message';
import {
  chooseSendingLocationForContact,
  getExistingAvailableNumber,
  getExistingPendingRequest,
  getRedis,
} from '../lib/redis';
import { handlePhoneNumberRequestFulfillment } from '../lib/redis/existing-pending-request';
import { RedisClient } from '../lib/redis/redis-index';
import { logger, statsd } from '../logger';

export const PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER =
  'process-grey-route-message';
export const PROCESS_MESSAGE_IDENTIFIER = 'process-message';

const histogram = async <T>(
  fn: () => Promise<T>,
  metric: string,
  tags: string[] | ((result: T) => string[])
): Promise<T> => {
  const before = Date.now();
  const result = await fn();
  const after = Date.now();

  const resolvedTags = typeof tags === 'function' ? tags(result) : tags;

  if (statsd !== undefined) {
    try {
      statsd.histogram(metric, after - before, resolvedTags);
    } catch (ex) {
      logger.error('Error posting process-grey-route-message-run', ex);
    }
  }

  return result;
};

export const processGreyRouteMessage = async (
  client: PoolOrPoolClient,
  rawPayload: unknown,
  redis: RedisClient = getRedis()
) => {
  const payload = ProcessMessagePayloadSchema.parse(rawPayload);

  const before = Date.now();
  const result = await doProcessGreyRouteMessage(client, payload, redis);

  const runtime = Date.now() - before;

  if (statsd !== undefined) {
    try {
      statsd.histogram('worker.process_grey_route_message.run_time', runtime, [
        `profile_id:${result.profile_id}`,
        `sending_location_id:${result.sending_location_id}`,
        `decision_stage:${result.decision_stage}`,
      ]);
    } catch (ex) {
      logger.error('Error posting process-grey-route-message-run', ex);
    }
  }

  return result;
};

const doProcessGreyRouteMessage = async (
  client: PoolOrPoolClient,
  payload: ProcessMessagePayload,
  redis: RedisClient
) => {
  const { profile_id: profileId, id: messageId, to_number: toNumber } = payload;

  const loggingShared = { profileId, messageId };
  const debugLog = (msg: string, extra: Record<string, unknown>) => {
    logger.debug(`process-grey-route-message: ${msg}`, {
      ...extra,
      ...loggingShared,
    });
  };

  // First, check for a prev mapping
  const prevMappingRecord = await histogram(
    () => getFromNumberMapping(client, { toNumber, profileId }),
    'worker.prev_mapping_check.run_time',
    (record) => [
      `profile_id:${profileId}`,
      `found_prev_mapping:${record !== undefined}`,
    ]
  );

  debugLog('prev mapping check:', {
    prevMappingRecord,
    found: !!prevMappingRecord,
  });

  if (prevMappingRecord) {
    const firstFromToPairOfDay =
      isNil(prevMappingRecord.last_used_at) ||
      hoursBetweenDates(new Date(), prevMappingRecord.last_used_at) > 12;

    return histogram(
      () =>
        insert(client, 'outbound_messages_routing', {
          id: payload.id,
          profile_id: payload.profile_id,
          to_number: payload.to_number,
          decision_stage: DecisionStage.PrevMapping,
          stage: outbound_message_stages.Queued,
          from_number: prevMappingRecord.from_number,
          sending_location_id: prevMappingRecord.sending_location_id,
          estimated_segments: payload.estimated_segments,
          send_after: null,
          // payload.created_at is a string, but schemats wants dates for original_created_at
          // it's fine to pass in a string, and in fact it's the only way to ensure
          // exact precision from postgres back to postgres
          original_created_at: payload.created_at as unknown as Date,
          first_from_to_pair_of_day: firstFromToPairOfDay,
        }),
      'worker.insert_outbound_messages_routing.run_time',
      [
        `profile_id:${payload.profile_id}`,
        `sending_location_id:${prevMappingRecord.sending_location_id}`,
        `decision_stage:prev_mapping`,
        `first_from_to_pair_of_day:${firstFromToPairOfDay}`,
      ]
    );
  }

  // Next, check for a phone number with availability that is not overloaded
  const env = { redis, pg: client };

  const sendingLocationId = await histogram(
    () =>
      chooseSendingLocationForContact(env, profileId, {
        contactZipCode: payload.contact_zip_code,
      }),
    'worker.choose_sending_location_for_contact.run_time',
    [`profile_id:${payload.profile_id}`]
  );

  debugLog('choose sending location:', { sendingLocationId });

  if (!sendingLocationId) {
    throw new Error(
      `No sending location found for profile ${profileId} for zip code ${payload.contact_zip_code}`
    );
  }

  const chosenFromNumber = await histogram(
    async () => {
      return getExistingAvailableNumber(env, payload.profile_id, {
        sendingLocationId,
      });
    },
    'worker.choose_existing_available_number.run_time',
    (result) => [
      `profile_id:${payload.profile_id}`,
      `chose_a_number:${result !== undefined}`,
    ]
  );

  if (chosenFromNumber) {
    debugLog('choosing a number - chose', { chosenFromNumber });

    return histogram(
      () =>
        insert(client, 'outbound_messages_routing', {
          id: payload.id,
          profile_id: payload.profile_id,
          to_number: payload.to_number,
          decision_stage: DecisionStage.ExistingPhoneNumber,
          stage: outbound_message_stages.Queued,
          from_number: chosenFromNumber,
          sending_location_id: sendingLocationId,
          estimated_segments: payload.estimated_segments,
          send_after: null,
          // payload.created_at is a string, but schemats wants dates for original_created_at
          // it's fine to pass in a string, and in fact it's the only way to ensure
          // exact precision from postgres back to postgres
          original_created_at: payload.created_at as unknown as Date,
          first_from_to_pair_of_day: true,
        }),
      'worker.insert_outbound_messages_routing.run_time',
      [
        `profile_id:${payload.profile_id}`,
        `sending_location_id:${sendingLocationId}`,
        `decision_stage:existing_phone_number`,
        'first_from_to_pair_of_day:true',
      ]
    );
  }

  // Map to an existing request
  const existingPendingRequestId = await histogram(
    () => getExistingPendingRequest(env, profileId, { sendingLocationId }),
    'worker.get_existing_pending_reqeust.run_time',
    (result) => [
      `profile_id:${payload.profile_id}`,
      `chose_a_pending_request:${result !== undefined}`,
    ]
  );

  debugLog('existing pending request', { existingPendingRequestId });

  if (existingPendingRequestId) {
    const {
      rows: [phoneNumberRequest],
    } = await histogram(
      async () => {
        return client.query<phone_number_requests>(
          'select * from sms.phone_number_requests where id = $1',
          [existingPendingRequestId]
        );
      },
      'worker.check_request_not_fulfilled.run_time',
      [
        `profile_id:${payload.profile_id}`,
        `sending_location_id:${sendingLocationId}`,
        `decision_stage:existing_pending_request`,
      ]
    );

    if (!!phoneNumberRequest.fulfilled_at) {
      // This is unexpected but happening!
      // We need to make sure it's marked as fulfilled, and we should throw an error here
      await handlePhoneNumberRequestFulfillment(
        env.redis,
        profileId,
        sendingLocationId,
        existingPendingRequestId
      );

      throw new Error(
        `Error: routing to phone number request that is already fulfilled: ${existingPendingRequestId}`
      );
    }

    return histogram(
      () =>
        insert(client, 'outbound_messages_awaiting_from_number', {
          id: payload.id,
          profile_id: payload.profile_id,
          to_number: payload.to_number,
          decision_stage: DecisionStage.ExistingPendingRequest,
          sending_location_id: sendingLocationId,
          pending_number_request_id: existingPendingRequestId,
          estimated_segments: payload.estimated_segments,
          send_after: null,
          // payload.created_at is a string, but schemats wants dates for original_created_at
          // it's fine to pass in a string, and in fact it's the only way to ensure
          // exact precision from postgres back to postgres
          original_created_at: payload.created_at as unknown as Date,
        }),
      'worker.insert_outbound_messages_routing.run_time',
      [
        `profile_id:${payload.profile_id}`,
        `sending_location_id:${sendingLocationId}`,
        `decision_stage:existing_pending_request`,
      ]
    );
  }

  // Finally, create a new request if none exists
  const areaCode = await chooseAreaCodeForSendingLocation(
    client,
    sendingLocationId
  );

  const pnr = await insert(
    client,
    'phone_number_requests',
    {
      sending_location_id: sendingLocationId,
      area_code: areaCode,
    },
    profileId
  );

  return histogram(
    () =>
      insert(client, 'outbound_messages_awaiting_from_number', {
        id: payload.id,
        profile_id: payload.profile_id,
        to_number: payload.to_number,
        decision_stage: DecisionStage.NewPendingRequest,
        sending_location_id: sendingLocationId,
        pending_number_request_id: pnr.id,
        estimated_segments: payload.estimated_segments,
        // payload.created_at is a string, but schemats wants dates for original_created_at
        // it's fine to pass in a string, and in fact it's the only way to ensure
        // exact precision from postgres back to postgres
        original_created_at: payload.created_at as unknown as Date,
      }),
    'worker.insert_outbound_messages_routing.run_time',
    [
      `profile_id:${payload.profile_id}`,
      `sending_location_id:${sendingLocationId}`,
      `decision_stage:existing_pending_request`,
    ]
  );
};
