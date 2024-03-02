import RedisMock from 'ioredis-mock';
import { Pool } from 'pg';

import config from '../../config';
import { outbound_message_stages } from '../db-types';
import { resetEmitters, SwitchboardEmitter } from '../emitter';
import { sleep } from '../utils';
import {
  constructMethodFromIndexSpec,
  IndexContext,
  RedisClient,
  RedisIndexSpec,
  resetAllHydrationState,
} from './redis-index';

const fakeRedis = new RedisMock() as RedisClient;

describe('redis index shared functionality', () => {
  let pool: Pool;
  let testEnv: IndexContext;

  beforeEach(async () => {
    pool = new Pool({ connectionString: config.databaseUrl });
    testEnv = {
      redis: fakeRedis,
      pg: pool,
    };
    resetEmitters();
    await resetAllHydrationState(fakeRedis);
  });

  afterEach(async () => {
    return pool.end();
  });

  test('should not hydrate twice', async () => {
    const mock = jest.fn();

    const DUMMY_INDEX: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy-double-hydrate-test',
      hydrate: async () => {
        mock();
        await sleep(100);
      },
      fn: async () => {
        return 4;
      },
    };

    const fn = constructMethodFromIndexSpec(DUMMY_INDEX);
    await Promise.all([
      fn(testEnv, 'profile-1', undefined),
      fn(testEnv, 'profile-1', undefined),
    ]);

    expect(mock).toHaveBeenCalledTimes(1);
  });

  test('calling one function calls all hydrators for profile', async () => {
    const mock1 = jest.fn();
    const mock2 = jest.fn();

    const DUMMY_INDEX_1: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy',
      hydrate: async () => {
        mock1();
        await sleep(10);
      },
      fn: async () => {
        return 4;
      },
    };

    const DUMMY_INDEX_2: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy-all-profile-test',
      hydrate: async () => {
        mock2();
        await sleep(10);
      },
      fn: async () => {
        return 4;
      },
    };

    const fn1 = constructMethodFromIndexSpec(DUMMY_INDEX_1);
    const fn2 = constructMethodFromIndexSpec(DUMMY_INDEX_2);

    await fn1(testEnv, 'profile-1', undefined);

    expect(mock1).toHaveBeenCalled();
    // fn2 is not called
    expect(mock2).toHaveBeenCalled();
  });

  test('hydration status is profile scoped', async () => {
    const mock = jest.fn();

    const DUMMY_INDEX: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy-profile-scope-test',
      hydrate: async (env, profileId) => {
        mock(profileId);
      },
      fn: async () => {
        return 4;
      },
    };

    const fn = constructMethodFromIndexSpec(DUMMY_INDEX);

    await Promise.all([
      fn(testEnv, 'profile-1', undefined),
      fn(testEnv, 'profile-2', undefined),
    ]);

    expect(mock).toHaveBeenCalledTimes(2);
    expect(mock).toHaveBeenCalledWith('profile-1');
    expect(mock).toHaveBeenCalledWith('profile-2');
  });

  test('rehydrate means subsequent calls rehydrate', async () => {
    const mock = jest.fn();

    const DUMMY_INDEX: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy-rehydrate-test',
      hydrate: async (env, profileId) => {
        mock(profileId);
      },
      fn: async () => {
        return 4;
      },
      addHandlers: (emitter, env, profileId, rehydrate) => {
        emitter.on(profileId, 'inserted:outbound_messages', async () => {
          await rehydrate();
        });

        return () => {
          emitter.offAll(profileId, 'inserted:outbound_messages');
        };
      },
    };

    const fn = constructMethodFromIndexSpec(DUMMY_INDEX);
    await fn(testEnv, 'profile-1', undefined);
    await fn(testEnv, 'profile-1', undefined);

    expect(mock).toHaveBeenCalledTimes(1);

    SwitchboardEmitter.emit('profile-1', 'inserted:outbound_messages', {
      id: 'id',
      created_at: new Date(),
      contact_zip_code: '11238',
      stage: outbound_message_stages.Processing,
      body: 'hello',
      to_number: '+15555555555',
    });

    await fn(testEnv, 'profile-1', undefined);
    expect(mock).toHaveBeenCalledTimes(2);
  });

  test('handlers get mounted on function call', async () => {
    const mock = jest.fn();

    const DUMMY_INDEX: RedisIndexSpec<unknown, unknown> = {
      name: 'dummy-handler-test',
      hydrate: async () => {
        // pass
      },
      fn: async () => {
        await sleep(10);
        return 4;
      },
      addHandlers: (emitter, env, profileId, rehydrate) => {
        emitter.on(profileId, 'inserted:outbound_messages', async (payload) => {
          mock();
        });

        return () => {
          emitter.offAll(profileId, 'inserted:outbound_messages');
        };
      },
    };

    const fn = constructMethodFromIndexSpec(DUMMY_INDEX);

    await fn(testEnv, 'profile-1', undefined);

    SwitchboardEmitter.emit('profile-1', 'inserted:outbound_messages', {
      id: 'id',
      created_at: new Date(),
      contact_zip_code: '11238',
      stage: outbound_message_stages.Processing,
      body: 'hello',
      to_number: '+15555555555',
    });

    await fn(testEnv, 'profile-1', undefined);

    expect(mock).toHaveBeenCalled();
  });
});
