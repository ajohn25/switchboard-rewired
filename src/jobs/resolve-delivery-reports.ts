import { Task } from 'graphile-worker';

import { GraphileCronItemPayloadSchema } from './schema-validation';

export const RESOLVE_DELIVERY_REPORTS_IDENTIFIER = 'resolve-delivery-reports';

export const resolveDeliveryReports: Task = async (rawPayload, helpers) => {
  const payload = GraphileCronItemPayloadSchema.parse(rawPayload);
  await helpers.withPgClient(async (client) => {
    await client.query(`select sms.resolve_delivery_reports($1, $2, $3)`, [
      '5 minutes',
      '10 seconds',
      payload._cron.ts,
    ]);
  });
};
