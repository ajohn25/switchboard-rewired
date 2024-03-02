import reverse from 'lodash/reverse';
import { Pool, PoolClient } from 'pg';

import {
  PoolClientInTransaction,
  withClient,
  WithClientCallback,
} from '../lib/db';

interface PgMiddleware {
  after: string;
  before: string;
}

export const withPgMiddlewares = async <T>(
  pool: Pool,
  middlewares: PgMiddleware[],
  callback: WithClientCallback<T>
) =>
  withClient(pool, async (client) => {
    for (const middleware of middlewares) {
      await client.query(middleware.before);

      // Let other parts of the code know that we're in a transaction
      // to avoid accidentally running commit on a test that should
      // be rolled back
      if (middleware.before === 'begin') {
        (client as PoolClientInTransaction).inTransaction = true;
      }
    }

    const result = await callback(client);

    for (const middleware of reverse(middlewares)) {
      await client.query(middleware.after);

      if (middleware.after === 'rollback' || middleware.after === 'commit') {
        (client as PoolClientInTransaction).inTransaction = false;
      }
    }

    return result;
  });

/**
 * This cannot be used simultaneous with other transactions
 */
export const autoRollbackMiddleware: PgMiddleware = {
  after: 'rollback',
  before: 'begin',
};

export const disableTriggersMiddleware: PgMiddleware = {
  after: `set session_replication_role to default`,
  before: `set session_replication_role to 'replica'`,
};

export const withReplicaMode = async <T>(
  client: PoolClient,
  callback: WithClientCallback<T>
) => {
  try {
    await client.query(disableTriggersMiddleware.before);
    const result = await callback(client);
    return result;
  } finally {
    await client.query(disableTriggersMiddleware.after);
  }
};
