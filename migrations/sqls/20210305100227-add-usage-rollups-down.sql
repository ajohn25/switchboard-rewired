-- Revert outbound message usage function
-- ------------------------------------------------------------

drop function billing.outbound_message_usage(uuid, timestamp with time zone);

CREATE FUNCTION billing.outbound_message_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, sms_segments bigint, mms_segments bigint, queued_messages bigint)
    LANGUAGE plpgsql
    AS $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media = 0) as sms_segments,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media > 0) as mms_segments,
    count(1) filter (where stage = 'queued' or stage = 'awaiting-number') as queued_messages
  from sms.outbound_messages
  join sms.sending_locations
    on sms.sending_locations.id = sms.outbound_messages.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = client
    and sms.outbound_messages.created_at >= v_month_start
    and sms.outbound_messages.created_at < v_month_end
  group by 1, 4
  order by
    sms_segments desc;
end;
$$;

-- Revert usage rollup changes
-- ------------------------------------------------------------

alter table sms.outbound_messages_telco
  drop column sent_at;

drop function billing.generate_usage_rollups(timestamp);
drop index sms.inbound_messages_received_at;

drop table billing.lrn_usage_rollups;
drop table billing.messaging_usage_rollups;

drop procedure billing.incremental_rollup_backfill_from;
drop function billing.backfill_telco_sent_at_around;
