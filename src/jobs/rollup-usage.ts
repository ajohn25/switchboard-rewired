import { Task } from 'graphile-worker';

import { GraphileCronItemPayloadSchema } from './schema-validation';

export const ROLLUP_USAGE_IDENTIFIER = 'rollup-usage';

export const rollupUsage: Task = async (rawPayload, helpers) => {
  const payload = GraphileCronItemPayloadSchema.parse(rawPayload);
  await helpers.withPgClient((client) =>
    client.query(`select billing.generate_usage_rollups($1)`, [
      payload._cron.ts,
    ])
  );
};
