import type { Task } from 'graphile-worker';

export const TRUNCATE_DAILY_TABLES_IDENTIFIER = 'truncate-daily-tables';

export const truncateDailyTables: Task = async (_payload, helpers) => {
  await helpers.withPgClient(async (client) => {
    await client.query('truncate sms.fresh_phone_commitments');
  });
};
