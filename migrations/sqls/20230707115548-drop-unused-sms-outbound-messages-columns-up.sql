-- Drop dependencies on deprecated columns
-- --------------------------------------------

-- This was used for end of month billing before splitting messages tables. Deprecated in:
-- https://github.com/politics-rewired/assemble-scripts/commit/a0699686d56526c35e6fcae6fe7f8f2a3150d127
drop function billing.outbound_message_usage;

-- Could not find any reference to this function in GitHub issues or Notion
drop function sms.backfill_pending_request_commitment_counts;

-- Could not find any reference to this function in GitHub issues or Notion
-- Added in https://github.com/politics-rewired/switchboard/pull/86 with no description of use
drop view billing.past_month_outbound_sms;


-- Remove columns on sms.outbound_messages that have been moved to other tables
-- ----------------------------------------------------------------------------

alter table sms.outbound_messages
  -- Columns moved to sms.outbound_messages_routing
  drop column decision_stage,
  drop column processed_at,
  drop column sending_location_id,
  drop column from_number,
  drop column first_from_to_pair_of_day,
  -- Columns moved to sms.outbound_messages_awaiting_from_number
  drop column pending_number_request_id,
  drop column send_after,
  -- Columns moved to sms.outbound_messages_telco
  drop column service_id,
  drop column num_segments,
  drop column num_media,
  drop column cost_in_cents,
  drop column extra;
