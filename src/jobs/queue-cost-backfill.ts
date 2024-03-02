import { Task } from 'graphile-worker';

import { BACKFILL_COST_IDENTIFIER } from './backfill-cost';
import { GraphileCronItemPayloadSchema } from './schema-validation';

export const QUEUE_COST_BACKFILL_IDENTIFIER = 'queue-cost-backfill';

export const queueCostBackfill: Task = async (rawPayload, helpers) => {
  const payload = GraphileCronItemPayloadSchema.parse(rawPayload);
  // We want to give Twilio 2 days to backfill the jobs
  // and we want to run these nightly
  // so we're always backfilling between 3 days ago and 2 days ago
  // to avoid twilio rate limits, we'll run one at a time per sending account
  await helpers.query(
    `
      select graphile_worker.add_job(
        $1,
        (json_build_object(
          'from_number', phone_number,
          'starting_at', date_trunc('day', cast($2 as timestamptz) - interval '3 days' - interval '1 second'),
          'ending_at', date_trunc('day', cast($2 as timestamptz) - interval '2 days')
        )::jsonb || json_build_object(
          'sending_account_id', sms.sending_accounts.id,
          'service', sms.sending_accounts.service,
          'twilio_credentials', sms.sending_accounts.twilio_credentials,
          'telnyx_credentials', sms.sending_accounts.telnyx_credentials
        )::jsonb)::json,
        queue_name => 'backfill-cost-' || sending_account_id
      )
      from sms.phone_numbers
      join sms.sending_locations
        on sms.sending_locations.id = sms.phone_numbers.sending_location_id
      join sms.profiles
        on sms.profiles.id = sms.sending_locations.profile_id
      join sms.sending_accounts
        on sms.sending_accounts.id = sms.profiles.sending_account_id
      where sms.sending_accounts.service = 'twilio'
        and sms.sending_accounts.run_cost_backfills = true
    `,
    [BACKFILL_COST_IDENTIFIER, payload._cron.ts]
  );
};
