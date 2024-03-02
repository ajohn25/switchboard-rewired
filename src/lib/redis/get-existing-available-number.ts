import flatten from 'lodash/flatten';
import groupBy from 'lodash/groupBy';
import memoize from 'lodash/memoize';

import { ChainableCommander } from 'ioredis';
import { PoolOrPoolClient } from '../../db';
import { logger } from '../../logger';
import { profiles } from '../db-types';
import { nowAsDate } from '../utils';
import { RedisClient, RedisIndexSpec } from './redis-index';

const getDailyContactLimit = memoize(
  async (profileId: string, redis: RedisClient): Promise<number> => {
    const asString = await redis.get(`${profileId}-dailyContactLimit`);
    return parseInt(asString!, 10);
  }
);

// These functions use nowAsDate to enable mocking of the current time
const nMinutesFromNow = (n: number) => {
  const d = nowAsDate();
  d.setMinutes(d.getMinutes() + n);
  return d.getTime();
};

const SECONDS_IN_A_MINUTE = 60;
const getMsPerSegment = (
  throughputIntervalInMinutes: number,
  throughputLimit: number
) => {
  const secondsPerSegment =
    (SECONDS_IN_A_MINUTE * throughputIntervalInMinutes) / throughputLimit;
  return secondsPerSegment * 1000;
};

const currentTime = () => {
  const d = nowAsDate();
  return d.getTime();
};

export const getThroughputLimit = memoize(
  async (profileId: string, redis: RedisClient) => {
    return redis
      .get(`${profileId}-throughputLimit`)
      .then((value) => parseInt(value!, 10));
  }
);

export const getThroughputIntervalMinutes = memoize(
  async (profileId: string, redis: RedisClient) => {
    return redis
      .get(`${profileId}-throughputIntervalMinutes`)
      .then((value) => parseInt(value!, 10));
  }
);

type AddCommandToPipelineFn = (
  pipeline: ChainableCommander
) => ChainableCommander;
type Hydrator = (
  pg: PoolOrPoolClient,
  profileId: string
) => Promise<AddCommandToPipelineFn>;

const todaysUsageHydrator: Hydrator = async (pg, profileId) => {
  const { rows: todaysUsage } = await pg.query<{
    count_recipients: number;
    from_number: string;
    sending_location_id: string;
  }>(
    `
    select count(distinct to_number) as count_recipients, from_number, sending_location_id
    from sms.outbound_messages_routing r
    where original_created_at > date_trunc('day', 'now'::timestamptz at time zone 'America/Los_Angeles') at time zone 'UTC'
      and profile_id = $1
      and not exists (
        select 1
        from sms.phone_numbers pn
        where pn.cordoned_at is not null
          and pn.phone_number = r.from_number
      )
    group by 2, 3

    union all

    select 0 as count_recipients, phone_number as from_number, sending_location_id
    from sms.phone_numbers pn
    where sending_location_id in ( select id from sms.sending_locations where profile_id = $1 )
      and cordoned_at is null
      and not exists (
        select 1
        from sms.outbound_messages_routing r
        where original_created_at > date_trunc('day', 'now'::timestamptz at time zone 'America/Los_Angeles') at time zone 'UTC' 
          and r.from_number = pn.phone_number
      )
    `,
    [profileId]
  );

  const groupedBySendingLocation = groupBy(
    todaysUsage,
    (u) => u.sending_location_id
  );

  const sendingLocations = Object.keys(groupedBySendingLocation);

  return (pipeline: ChainableCommander) => {
    return sendingLocations.reduce((pipe, sendingLocationId) => {
      const todaysUsageForSendingLocation =
        groupedBySendingLocation[sendingLocationId];

      const flattenedScoreMemberPairs = flatten(
        todaysUsageForSendingLocation.map((u) => [
          u.count_recipients,
          u.from_number,
        ])
      );

      const key = `${profileId}-${sendingLocationId}-availableNumbers`;
      return pipe.zadd(key, ...flattenedScoreMemberPairs);
    }, pipeline);
  };
};

const lastMinuteHydrator: Hydrator = async (pg, profileId) => {
  const { rows: lastMinute } = await pg.query<{
    count_segments: number;
    from_number: string;
    sending_location_id: string;
  }>(
    `
    select sum(estimated_segments) as count_segments, from_number, sending_location_id
    from sms.outbound_messages_routing
    where original_created_at > date_trunc('day', 'now'::timestamp at time zone 'America/Los_Angeles') at time zone 'UTC'
      and profile_id = $1
      and processed_at > 'now'::timestamp - (
        select throughput_interval
        from sms.profiles 
        where id = $1
      )
    group by 2, 3
  `,
    [profileId]
  );

  const groupedBySendingLocation = groupBy(
    lastMinute,
    (u) => u.sending_location_id
  );

  const sendingLocations = Object.keys(groupedBySendingLocation);

  return (pipeline) =>
    sendingLocations.reduce((pipe, sendingLocationId) => {
      const todaysUsageForSendingLocation =
        groupedBySendingLocation[sendingLocationId];

      const flattenedScoreMemberPairs = flatten(
        todaysUsageForSendingLocation.map((u) => [
          u.count_segments,
          u.from_number,
        ])
      );

      const key = `${profileId}-${sendingLocationId}-recentUsage`;
      return pipe.hmset(key, ...flattenedScoreMemberPairs);
    }, pipeline);
};

const profileConfigHydrator: Hydrator = async (pg, profileId) => {
  const {
    rows: [profile],
  } = await pg.query<profiles>('select * from sms.profiles where id = $1', [
    profileId,
  ]);

  // schemats incorrectly types intervals - they are available by their components
  // like { minutes : 1 }
  const throughputInterval = (profile.throughput_interval as any).minutes;

  if (throughputInterval === undefined) {
    logger.error(
      `Error with profile ${profileId} - throughput_interval is not defined as a simple statement about minutes:`,
      profile.throughput_interval
    );
    throw new Error(
      `Error with profile ${profileId} - throughput_interval is not defined as a simple statement about minutes:`
    );
  }

  return (pipeline) =>
    pipeline
      .set(`${profileId}-throughputLimit`, profile.throughput_limit)
      .set(`${profileId}-throughputIntervalMinutes`, throughputInterval)
      .set(`${profileId}-dailyContactLimit`, profile.daily_contact_limit);
};

export const GET_EXISTING_AVAILABLE_NUMBER: RedisIndexSpec<
  string | undefined,
  { sendingLocationId: string }
> = {
  name: 'getExistingAvailableNumber',
  fn: async ({ redis }, profileId, param) => {
    const availableNumbersKey = `${profileId}-${param.sendingLocationId}-availableNumbers`;
    const nextSendAbleKey = `${profileId}-${param.sendingLocationId}-nextSendable`;

    const dailyContactLimit = await getDailyContactLimit(profileId, redis);
    const throughputIntervalInMinutes = await getThroughputIntervalMinutes(
      profileId,
      redis
    );

    const result = await redis.getexistingavailablenumber(
      availableNumbersKey,
      nextSendAbleKey,
      dailyContactLimit,
      nMinutesFromNow(throughputIntervalInMinutes)
    );

    return result as string | undefined;
  },
  hydrate: async ({ pg, redis }, profileId) => {
    const fns = await Promise.all([
      todaysUsageHydrator(pg, profileId),
      lastMinuteHydrator(pg, profileId),
      profileConfigHydrator(pg, profileId),
    ]);

    const pipeline = fns.reduce((pipe, fn) => fn(pipe), redis.pipeline());
    await pipeline.exec();
  },
  addHandlers: (emitter, { redis, pg }, profileId) => {
    emitter.on(profileId, 'inserted:outbound_messages_routing', async (r) => {
      let pipeline = redis.pipeline();

      const todaysUsageKey = `${profileId}-${r.sending_location_id}-availableNumbers`;
      const nextSendAbleKey = `${profileId}-${r.sending_location_id}-nextSendable`;

      if (r.first_from_to_pair_of_day) {
        pipeline = pipeline.zincrby(todaysUsageKey, 1, r.from_number!);
      }

      const [throughputIntervalInMinutes, throughputLimit] = await Promise.all([
        getThroughputIntervalMinutes(profileId, redis),
        getThroughputLimit(profileId, redis),
      ]);

      const now = currentTime();
      const incrementAmount = getMsPerSegment(
        throughputIntervalInMinutes,
        throughputLimit
      );

      pipeline.updatenextsendableby(
        nextSendAbleKey,
        r.from_number!,
        incrementAmount,
        now
      );

      await pipeline.exec();
    });

    emitter.on(
      profileId,
      'fulfilled:phone_number_request',
      async (pnrUpdate) => {
        const key = `${profileId}-${pnrUpdate.sending_location_id}-availableNumbers`;

        const [countToBeSent, countSent] = await Promise.all([
          pg
            .query<{ count_to_be_sent: number }>(
              `
                select count(*) as count_to_be_sent
                from sms.outbound_messages_awaiting_from_number
                where pending_number_request_id = $1
              `,
              [pnrUpdate.id]
            )
            .then((r) => r.rows[0].count_to_be_sent),

          pg
            .query<{ count_sent: number }>(
              `
                select count(*) as count_sent
                from sms.outbound_messages_routing
                where from_number = $1
                  and original_created_at > 'now'::timestamp - interval '1 day'
              `,
              [pnrUpdate.phone_number]
            )
            .then((r) => r.rows[0].count_sent),
        ]);

        await redis.zadd(
          key,
          countSent + countToBeSent,
          pnrUpdate.phone_number!
        );
      }
    );

    return () => {
      emitter.offAll(profileId, 'inserted:outbound_messages_routing');
      emitter.offAll(profileId, 'fulfilled:phone_number_request');
    };
  },
};
