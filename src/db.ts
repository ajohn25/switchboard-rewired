/// <reference> "./src/typings/slonik.d.ts"
import { Pool, PoolClient } from 'pg';
import { parse } from 'pg-connection-string';
import { ClientConfiguration, createPool, sql } from 'slonik';

import config from './config';

type ActualPgConfigSsl =
  | boolean
  | string
  | Partial<{
      rejectUnauthorized: boolean;
      cert: string;
      key: string;
      ca: string;
    }>;

const pgConfig = parse(config.databaseUrl);
const ssl = pgConfig.ssl as ActualPgConfigSsl;

const clientConnectionConfiguration: Partial<ClientConfiguration> = {
  maximumPoolSize: config.maxPoolSize,
  ...(typeof ssl === 'object' ? { ssl } : {}),
};

async function db<T = any>(query: any) {
  const result = await pool.query<T>(query);
  const rows = result.rows;
  return rows;
}

const pool = createPool(config.databaseUrl, clientConnectionConfiguration);

const pgPool = new Pool({
  connectionString: config.databaseUrl,
  max: config.maxPoolSize,
});

type PoolOrPoolClient = Pool | PoolClient;

export { db, pool, pgPool, sql, PoolOrPoolClient };
