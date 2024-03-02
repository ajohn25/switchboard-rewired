import { PoolClient } from 'pg';
import { z } from 'zod';

import { CodedSendMessageError, InvalidFromNumberError } from '../lib/errors';
import { getTelcoClient } from '../lib/services';
import {
  DeliveryReportEvent,
  SwitchboardErrorCodes,
  WrappableTask,
} from '../lib/types';
import { sendingAccountCache } from '../models/cache';
import { ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER } from './associate-service-profile-to-phone-number';
import { ProfileSendingAccountPayloadSchema } from './schema-validation';

export const SEND_MESSAGE_IDENTIFIER = 'send-message';

// tslint:disable-next-line variable-name
export const SendMessagePayloadSchema = ProfileSendingAccountPayloadSchema.pick(
  {
    profile_id: true,
    service: true,
    sending_account_id: true,
  }
)
  .extend({
    id: z.string().uuid(),
    body: z.string(),
    original_created_at: z.string(),
    sending_location_id: z.string().uuid(),
    to_number: z.string(),
    from_number: z.string(),
    media_urls: z.array(z.string()).nullable(),
    send_before: z.string().nullable(),
  })
  .required();

export type SendMessagePayload = z.infer<typeof SendMessagePayloadSchema>;

export interface OkSendMessageFnResponse {
  serviceId: string;
  numSegments: number;
  numMedia: number;
  costInCents: number | null;
  extra?: any;
}

const validateSendBefore = async (payload: SendMessagePayload) => {
  const sendBefore = payload.send_before
    ? new Date(payload.send_before)
    : undefined;

  if (sendBefore !== undefined && sendBefore < new Date()) {
    throw new CodedSendMessageError(SwitchboardErrorCodes.CouldNotSendInTime);
  }
};

const handleCodedError = async (
  client: PoolClient,
  err: CodedSendMessageError,
  payload: SendMessagePayload
) => {
  await client.query(
    'insert into sms.outbound_messages_telco (id, original_created_at, telco_status, profile_id) values ($1, $2, $3, $4)',
    [payload.id, payload.original_created_at, 'failed', payload.profile_id]
  );

  await client.query(
    `
      insert into sms.delivery_reports (message_id, event_type, generated_at, validated, error_codes, service, is_from_service)
      values ($1, $2, $3, $4, $5, $6, false)
    `,
    [
      payload.id,
      DeliveryReportEvent.DeliveryFailed,
      new Date(),
      true,
      [err.errorCode],
      payload.service,
    ]
  );
};

const handleMessageSent = async (
  client: PoolClient,
  payload: SendMessagePayload,
  message: OkSendMessageFnResponse
) => {
  await client.query(
    `
      insert into sms.outbound_messages_telco
      (id, original_created_at, telco_status, service_id, num_segments, num_media, cost_in_cents, extra, profile_id)
      values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    `,
    [
      payload.id,
      payload.original_created_at,
      'sent',
      message.serviceId,
      message.numSegments,
      message.numMedia,
      message.costInCents,
      message.extra,
      payload.profile_id,
    ]
  );
};

const handleInvalidFromNumber = async (
  client: PoolClient,
  phoneNumber: string
) => {
  const payload = { phone_number: phoneNumber };
  await client.query(
    `select graphile_worker.add_job($1, $2, max_attempts := 6, job_key := $3)`,
    [ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER, payload, phoneNumber]
  );
};

/**
 *  Sends the message using the proper profile parameters – sets
 *  the message stage to be 'sent', and 'service_id' to be the returned service_id,
 *  and extra billing related info (segment and media count)
 * @param client PoolClient
 * @param payload SendMessagePayload
 */
export const sendMessage: WrappableTask = async (
  client,
  rawPayload
): Promise<void> => {
  const payload = SendMessagePayloadSchema.parse(rawPayload);
  const { sending_account_id } = payload;
  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sending_account_id
  );
  try {
    await validateSendBefore(payload);
    const message = await getTelcoClient(sendingAccount).sendMessage(payload);
    await handleMessageSent(client, payload, message);
  } catch (err) {
    if (err instanceof CodedSendMessageError) {
      await handleCodedError(client, err, payload);
    } else if (err instanceof InvalidFromNumberError) {
      await handleInvalidFromNumber(client, payload.from_number);
      // TODO: reschedule this send-message job for 1 minute in the future once assemble-worker exposes helpers
      throw err;
    } else {
      throw err;
    }
  }
};
