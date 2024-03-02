import { JobHelpers, Task } from 'graphile-worker';
import { getRedis } from '../lib/redis';
import { RedisClient, resetAllHydrationState } from '../lib/redis/redis-index';

export const FLUSH_REDIS_IDENTIFIER = 'flush-redis';

export const flushRedis: Task = async (
  payload: unknown,
  helpers: JobHelpers,
  redis: RedisClient = getRedis()
) => {
  await resetAllHydrationState(redis);
};
