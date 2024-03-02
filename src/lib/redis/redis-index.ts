import { Redis } from 'ioredis';
import type { Dictionary } from 'lodash';
import redisLock from 'redis-lock';
import { promisify } from 'util';

import { PoolOrPoolClient } from '../../db';
import { SwitchboardEmitter } from '../emitter';

const withLock = async <T>(
  redis: RedisClient,
  key: string,
  fn: () => Promise<T>
): Promise<T> => {
  const getLock = promisify(redisLock(redis));
  const unlock = await getLock(key);
  try {
    return await fn();
  } catch (ex) {
    throw ex;
  } finally {
    await unlock();
  }
};

type Emitter = typeof SwitchboardEmitter;

export type RedisClient = Redis;

export interface IndexContext {
  redis: RedisClient;
  pg: PoolOrPoolClient;
}

type HydrateFn = (env: IndexContext, profileId: string) => Promise<void>;
type RehydrateFn = () => Promise<void>;

type IndexRetrievalFn<Result, Param = undefined> = (
  env: IndexContext,
  profileId: string,
  param: Param
) => Promise<Result>;

type OffFn = () => void;

export interface RedisIndexSpec<Result, Param = undefined> {
  fn: IndexRetrievalFn<Result, Param>;
  hydrate: HydrateFn;
  addHandlers?: (
    emitter: Emitter,
    env: IndexContext,
    profileId: string,
    rehydrate: RehydrateFn
  ) => OffFn;
  name: string;
}

type ReturnedFn<Result, Param = undefined> = (
  env: IndexContext,
  profileId: string,
  param: Param
) => Promise<Result>;

const handlers: Dictionary<OffFn> = {};

const allIndexes: Array<RedisIndexSpec<any, any>> = [];

const ensureAllHandlers = (
  env: IndexContext,
  profileId: string,
  rehydrate: RehydrateFn
) => {
  allIndexes.forEach((i) => {
    ensureHandlers(env, profileId, i, rehydrate);
  });
};

const ensureHandlers = (
  env: IndexContext,
  profileId: string,
  index: RedisIndexSpec<unknown, unknown>,
  rehydrate: RehydrateFn
) => {
  if (typeof index.addHandlers !== 'function') {
    return;
  }

  const key = `${profileId}-${index.name}`;
  if (handlers[key]) return;

  const offFn = index.addHandlers(
    SwitchboardEmitter,
    env,
    profileId,
    rehydrate
  );

  handlers[key] = offFn;
};

const HYDRATED_PROFILES_KEY = 'hydrated-profiles';

export const resetAllHydrationState = async (redis: RedisClient) => {
  await redis.flushall();
};

const checkIfHydrated = async (
  env: IndexContext,
  profileId: string
): Promise<boolean> => {
  const isMember = await env.redis.sismember(HYDRATED_PROFILES_KEY, profileId);
  return !!isMember;
};

const recordHydrationComplete = async (
  env: IndexContext,
  profileId: string
) => {
  await env.redis.sadd(HYDRATED_PROFILES_KEY, profileId);
};

const ensureHydratedRedisForProfile = async (
  env: IndexContext,
  profileId: string
) => {
  const { redis, pg } = env;

  const isHydrated = await checkIfHydrated(env, profileId);

  const rehydrate = async () => {
    await redis.srem(HYDRATED_PROFILES_KEY, profileId);
  };

  if (!isHydrated) {
    await withLock(redis, `${profileId}-hydration-lock`, async () => {
      const someOneElseHydrated = await checkIfHydrated(env, profileId);

      if (!someOneElseHydrated) {
        await Promise.all(allIndexes.map((i) => i.hydrate(env, profileId)));
        await recordHydrationComplete(env, profileId);
      }
    });
  }

  ensureAllHandlers(env, profileId, rehydrate);
};

export const constructMethodFromIndexSpec = <Result, Param = undefined>(
  index: RedisIndexSpec<Result, Param>
) => {
  allIndexes.push(index);

  const returnFn: ReturnedFn<Result, Param> = async (
    env: IndexContext,
    profileId: string,
    param: Param
  ) => {
    await ensureHydratedRedisForProfile(env, profileId);
    return index.fn(env, profileId, param);
  };
  return returnFn;
};
