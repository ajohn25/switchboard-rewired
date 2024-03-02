import { CronItem, Task } from 'graphile-worker';
import { z } from 'zod';

export const VACUUM_FULL_TABLE_IDENTIFIER = 'vacuum-full-table';

// tslint:disable-next-line variable-name
export const VacuumFullTablePayloadSchema = z
  .object({
    tableName: z.string(),
  })
  .required();

export type VacuumFullTablePayload = z.infer<
  typeof VacuumFullTablePayloadSchema
>;

export const vacuumFullTable: Task = async (payload, helpers) => {
  const { tableName } = VacuumFullTablePayloadSchema.parse(payload);

  await helpers.query(`vacuum full ${tableName}`);
};

export const vacuumCronItems = [
  'graphile_worker.jobs',
  'sms.unmatched_delivery_reports',
  'sms.outbound_messages_awaiting_from_number',
].map<CronItem>((tableName) => {
  const payload: VacuumFullTablePayload = { tableName };
  return {
    task: VACUUM_FULL_TABLE_IDENTIFIER,
    identifier: `${VACUUM_FULL_TABLE_IDENTIFIER}-${tableName}`,
    match: '0 6 * * *',
    payload,
    options: {
      backfillPeriod: 10 * 60 * 1000, // 10 minutes
      maxAttempts: 4,
    },
  };
});
