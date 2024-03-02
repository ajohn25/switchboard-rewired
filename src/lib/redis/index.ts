import { readFileSync } from 'fs';
import Redis, { Callback, Result } from 'ioredis';
import RedisMock from 'ioredis-mock';

import config from '../../config';
import { logger } from '../../logger';
import { CHOOSE_SENDING_LOCATION_FOR_CONTACT } from './choose-sending-location-for-contact';
import { GET_EXISTING_PENDING_REQUEST } from './existing-pending-request';
import { GET_EXISTING_AVAILABLE_NUMBER } from './get-existing-available-number';
import {
  constructMethodFromIndexSpec,
  RedisClient,
  resetAllHydrationState,
} from './redis-index';

export const defineCustomRedisCommands = (r: RedisClient): RedisClient => {
  r.defineCommand('getexistingavailablenumber', {
    lua: readFileSync('./lua/getexistingavailablenumber.lua').toString(),
    numberOfKeys: 0,
  });

  r.defineCommand('updatenextsendableby', {
    lua: readFileSync('./lua/updatenextsendableby.lua').toString(),
    numberOfKeys: 0,
  });

  return r;
};

// Add declarations
declare module 'ioredis' {
  interface RedisCommander<Context> {
    updatenextsendableby(
      key: string,
      phoneNumber: string,
      incrementAmount: number,
      now: number,
      callback?: Callback<string>
    ): Result<string, Context>;

    getexistingavailablenumber(
      availableNumbersKey: string,
      nextSendableKey: string,
      dailyContactLimit: number,
      tooFarInFuture: number
    ): Result<string, Context>;
  }
}

let redis: RedisClient;

export const getRedis = () => {
  if (config.isTest) {
    return defineCustomRedisCommands(new RedisMock());
  }
  if (redis) {
    return redis;
  }

  if (config.isTest) {
    const client = new RedisMock();
    redis = defineCustomRedisCommands(client);
    return redis;
  }
  if (!config.redisUrl) {
    throw new Error(`Missing REDIS_URL envvar!`);
  } else {
    const client = new Redis(config.redisUrl);
    redis = defineCustomRedisCommands(client);
  }

  // see "Connection Events": https://www.npmjs.com/package/ioredis
  redis.on('error', async (err) => {
    logger.error('Error connecting to redis', err);
    await resetAllHydrationState(redis);
  });

  redis.on('close', async () => {
    logger.info('Connection to redis closed');
    await resetAllHydrationState(redis);
  });

  return redis;
};

export const getExistingAvailableNumber = constructMethodFromIndexSpec(
  GET_EXISTING_AVAILABLE_NUMBER
);

export const chooseSendingLocationForContact = constructMethodFromIndexSpec(
  CHOOSE_SENDING_LOCATION_FOR_CONTACT
);

export const getExistingPendingRequest = constructMethodFromIndexSpec(
  GET_EXISTING_PENDING_REQUEST
);
