import flatten from 'lodash/flatten';
import groupBy from 'lodash/groupBy';
import memoize from 'lodash/memoize';

import { profiles } from '../db-types';
import { RedisClient, RedisIndexSpec } from './redis-index';

const getPendingRequestContactLimit = memoize(
  async (profileId: string, redis: RedisClient): Promise<number> => {
    const asString = await redis.get(`${profileId}-pendingRequestContactLimit`);
    return parseInt(asString!, 10);
  }
);

export const GET_EXISTING_PENDING_REQUEST: RedisIndexSpec<
  string,
  { sendingLocationId: string }
> = {
  name: 'existingPendingRequest',
  fn: async ({ redis }, profileId, param) => {
    const pendingRequestContactLimit = await getPendingRequestContactLimit(
      profileId,
      redis
    );

    const key = `${profileId}-${param.sendingLocationId}-existingPendingRequests`;

    const [returned] = await redis.zrangebyscore(
      key,
      -1,
      pendingRequestContactLimit,
      'LIMIT',
      0,
      1
    );

    return returned;
  },
  hydrate: async ({ pg, redis }, profileId) => {
    const { rows: pendingNumberRequests } = await pg.query<{
      count_awaiting: number;
      pending_number_request_id: string;
      sending_location_id: string;
    }>(`
        select count(*) as count_awaiting, sending_location_id, pending_number_request_id
        from sms.outbound_messages_awaiting_from_number
        group by 2, 3

        union all

        select 0 as count_awaiting, sending_location_id, id as pending_number_request_id
        from sms.phone_number_requests pnr
        where 
          fulfilled_at is null
          and not exists (
            select 1
            from sms.outbound_messages_awaiting_from_number afn
            where afn.pending_number_request_id = pnr.id
          )
      `);

    const bySendingLocation = groupBy(
      pendingNumberRequests,
      (pnr) => pnr.sending_location_id
    );

    const toExec = Object.keys(bySendingLocation).reduce(
      (multi, sendingLocationId) => {
        const key = `${profileId}-${sendingLocationId}-existingPendingRequests`;
        const kvPairs = flatten(
          bySendingLocation[sendingLocationId].map((pnr) => [
            pnr.count_awaiting,
            pnr.pending_number_request_id,
          ])
        );

        return multi.zadd(key, ...kvPairs);
      },
      redis.multi()
    );

    const {
      rows: [profile],
    } = await pg.query<profiles>('select * from sms.profiles where id = $1', [
      profileId,
    ]);

    await toExec
      .set(
        `${profileId}-pendingRequestContactLimit`,
        profile.daily_contact_limit
      )
      .exec();
  },
  addHandlers: (emitter, env, profileId) => {
    const { redis } = env;

    emitter.on(profileId, 'inserted:phone_number_requests', async (pnr) => {
      const key = `${profileId}-${pnr.sending_location_id}-existingPendingRequests`;
      await redis.zadd(key, 0, pnr.id);
    });

    emitter.on(
      profileId,
      'inserted:outbound_messages_awaiting_from_number',
      async (m) => {
        const existingPendingRequestsKey = `${profileId}-${m.sending_location_id}-existingPendingRequests`;
        const fulfilledPendingRequestsKey = `${profileId}-${m.sending_location_id}-fulfilledPendingRequests`;

        // Sometimes a message can come right after a fulfillment
        // If it does, we don't want to RE-add the fulfilled pending request to the sorted set
        const alreadyFulfilled = !!(await redis.sismember(
          fulfilledPendingRequestsKey,
          m.pending_number_request_id
        ));

        if (!alreadyFulfilled) {
          await redis.zincrby(
            existingPendingRequestsKey,
            1,
            m.pending_number_request_id
          );
        }
      }
    );

    emitter.on(
      profileId,
      'fulfilled:phone_number_request',
      async (pnrUpdate) => {
        await handlePhoneNumberRequestFulfillment(
          redis,
          profileId,
          pnrUpdate.sending_location_id,
          pnrUpdate.id
        );
      }
    );

    return () => {
      emitter.offAll(profileId, 'inserted:phone_number_requests');
      emitter.offAll(
        profileId,
        'inserted:outbound_messages_awaiting_from_number'
      );
      emitter.offAll(profileId, 'fulfilled:phone_number_request');
    };
  },
};

export const handlePhoneNumberRequestFulfillment = async (
  redis: RedisClient,
  profileId: string,
  sendingLocationId: string,
  pendingRequestId: string
) => {
  const existingPendingRequestsKey = `${profileId}-${sendingLocationId}-existingPendingRequests`;
  const fulfilledPendingRequestsKey = `${profileId}-${sendingLocationId}-fulfilledPendingRequests`;

  // Prevent it from being allocated to
  await redis
    .pipeline()
    .zrem(existingPendingRequestsKey, pendingRequestId)
    .sadd(fulfilledPendingRequestsKey, pendingRequestId)
    .exec();
};
