import { Client, Pool, PoolClient } from 'pg';

import { logger } from '../logger';

export type WithClientCallback<T> = (client: PoolClient) => Promise<T>;

export type ClientHandler<T, C extends PoolClient | Client> = (
  client: C
) => Promise<T>;

export const withClient = async <T>(
  pool: Pool,
  callback: WithClientCallback<T>
) => {
  const client = await pool.connect();
  try {
    return await callback(client);
  } catch (ex) {
    // Logging the error gives us more info
    // especially when the error comes from inside of a Postgres procedure
    // line number of procedure, etc.
    logger.error('Postgres error:', ex);
    throw ex;
  } finally {
    client.release();
  }
};

export type PoolClientInTransaction = PoolClient & { inTransaction: boolean };

const isAlreadyInTransaction = (client: PoolClient | PoolClientInTransaction) =>
  'inTransaction' in client && client.inTransaction;

export const withinTransaction = async <T>(
  client: Pool | PoolClient | PoolClientInTransaction,
  handler: WithClientCallback<T>
): Promise<T> => {
  if (client instanceof Pool) {
    return withClient(client, (realClient) =>
      withinTransaction(realClient, handler)
    );
  }

  const alreadyInTransaction = isAlreadyInTransaction(client);
  if (!alreadyInTransaction) {
    await client.query('begin');
  }

  try {
    const result = await handler(client);
    if (!alreadyInTransaction) {
      await client.query('commit');
    }
    return result;
  } catch (err) {
    if (!alreadyInTransaction) {
      await client.query('rollback');
    }
    throw err;
  }
};

export const withSavepoint = async <T, C extends Client | PoolClient>(
  client: C,
  name: string,
  handler: ClientHandler<T, C>
) => {
  await client.query(`SAVEPOINT ${name}`);
  try {
    const result = await handler(client);
    return result;
  } catch (e) {
    await client.query(`ROLLBACK TO SAVEPOINT ${name}`);
    throw e;
  } finally {
    await client.query(`RELEASE SAVEPOINT ${name}`);
  }
};

export const withRole = async <T, C extends Client | PoolClient>(
  client: C,
  role: string,
  handler: ClientHandler<T, C>
) => {
  const {
    rows: [{ current_user: originalRole }],
  } = await client.query<{ current_user: string }>(`select current_user`);
  await client.query(`SET ROLE ${role}`);
  try {
    const result = await handler(client);
    return result;
  } finally {
    await client.query(`SET ROLE ${originalRole}`);
  }
};
