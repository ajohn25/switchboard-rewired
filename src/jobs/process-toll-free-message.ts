import { PoolOrPoolClient } from '../db';
import { ProcessMessagePayloadSchema } from '../lib/process-message';
import { logger, statsd } from '../logger';

export const PROCESS_TOLL_FREE_MESSAGE_IDENTIFIER = 'process-toll-free-message';

export const processTollFreeMessage = async (
  client: PoolOrPoolClient,
  rawPayload: unknown
) => {
  const payload = ProcessMessagePayloadSchema.parse(rawPayload);

  const before = Date.now();

  const {
    rows: [{ pm: result }],
  } = await client.query(
    `select *
    from sms.outbound_messages m
    cross join lateral sms.process_toll_free_message(m) pm
    where m.id = $1 and m.created_at = $2`,
    [payload.id, payload.created_at]
  );
  const runtime = Date.now() - before;

  if (statsd !== undefined) {
    try {
      statsd.histogram('worker.process_toll_free_message.run_time', runtime, [
        `profile_id:${result.profile_id}`,
        `sending_location_id:${result.sending_location_id}`,
        `decision_stage:${result.decision_stage}`,
      ]);
    } catch (ex) {
      logger.error('Error posting process-toll-free-message-run', ex);
    }
  }

  return result;
};
