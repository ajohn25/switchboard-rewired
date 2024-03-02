import { CronItem, Task } from 'graphile-worker';

import superagent from 'superagent';
import config from '../../config';
import { GraphileCronItemPayloadSchema } from '../schema-validation';

export const SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER =
  'summarize-recent-failed-jobs';

export interface FailedJobSummaryRow {
  count: number;
  task_identifier: string;
  last_error: string;
}

export const summarizeRecentFailedJobs: Task = async (rawPayload, helpers) => {
  const payload = GraphileCronItemPayloadSchema.parse(rawPayload);

  if (!config.adminActionWebhookUrl) return;

  const { rows } = await helpers.query<FailedJobSummaryRow>(
    `
      select
        count(*) count,
        tasks.identifier as task_identifier,
        (case
          when last_error like 'Error: getaddrinfo ENOTFOUND%' then 'Error: getaddrinfo ENOTFOUND'
          when last_error like 'Error: bandwidth number order % was not successful. Got status FAILED' then 'bandwidth number order % was not successful. Got status FAILED'
          when last_error like 'error: duplicate key value violates unique constraint "%_outbound_messages_routing_pkey"' then 'duplicate key value -- outbound_messages_routing'
          when last_error like 'duplicate key value violates unique constraint "%_outbound_messages_routing_pkey"' then 'duplicate key value -- outbound_messages_routing'
          when last_error like 'error: duplicate key value violates unique constraint "%_outbound_messages_telco_pkey"' then 'duplicate key value -- outbound_messages_telco'
          when last_error like 'duplicate key value violates unique constraint "%_outbound_messages_telco_pkey"' then 'duplicate key value -- outbound_messages_telco'
          when last_error like 'No phone number matching % was found in this Twilio account' then 'No phone number matching % was found in this Twilio account'
          when last_error like 'No phone number matching % was found in this Telnyx account' then 'No phone number matching % was found in this Telnyx account'
          when last_error like 'Error: Permission to send an SMS has not been enabled for the region indicated by the ''To'' number: %.' then 'Error: Permission to send an SMS has not been enabled for the region indicated by the ''To'' number: %.'
          when last_error like 'Error: Invalid telnyx from number %' then 'Error: Invalid telnyx from number %'
          when last_error like '%got status 503 and body%' then '%got status 503 and body%'
          when last_error like '%got status 404 and body Tunnel%' then '%got status 404 and body Tunnel%'
          when last_error like 'error: No 10dlc number for profile: %, sending location %' then 'error: No 10dlc number for profile: %, sending location %'
          when last_error like '%unsolicited_message_messaging_service_sid_fkey%' then 'insert into unsolicited_message violates fk messaging_service_sid_fkey'
          when last_error like 'Error: Error: routing to phone number request that is already fulfilled: %' then 'Error: Error: routing to phone number request that is already fulfilled: %'
          else last_error
        end) as last_error
      from worker.failed_jobs
      join graphile_worker.tasks on tasks.id = failed_jobs.task_id
      where failed_at >= $1::timestamptz - '1 day'::interval
      group by 2, 3
      order by 2, 3
    `,
    [payload._cron.ts]
  );

  await superagent.post(config.adminActionWebhookUrl).send({
    event: SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
    summary: rows,
  });
};

export const summarizeRecentFailedJobsCronItem: CronItem = {
  task: SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
  identifier: SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
  match: '0 7 * * *', // Run once per hour, two minutes after the hour
  options: {
    backfillPeriod: 10 * 60 * 1000, // 10 minutes
    maxAttempts: 4,
  },
};
