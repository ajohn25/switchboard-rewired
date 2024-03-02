-- Restore columns on sms.outbound_messages
-- --------------------------------------------

alter table sms.outbound_messages
  add column sending_location_id uuid,
  add column from_number public.phone_number,
  add column pending_number_request_id uuid,
  add column service_id text,
  add column num_segments integer, 
  add column num_media integer, 
  add column extra json, 
  add column decision_stage text, 
  add column send_after timestamp without time zone,
  add column processed_at timestamp without time zone,
  add column cost_in_cents numeric(6,2),
  add column first_from_to_pair_of_day boolean DEFAULT true;

CREATE INDEX new_outbound_messages_phone_request_idx
 ON sms.outbound_messages
 USING btree (pending_number_request_id)
 WHERE (stage = 'awaiting-number'::sms.outbound_message_stages);

CREATE INDEX outbound_messages_service_id
  ON sms.outbound_messages
  USING btree (service_id)
  WHERE (service_id IS NOT NULL);


-- Restore dependencies on deprecated columns
-- --------------------------------------------

-- billing.outbound_message_usage

CREATE FUNCTION billing.outbound_message_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, sms_segments bigint, mms_segments bigint)
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
    p.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sa.service as service,
    sum(mt.num_segments) filter (where mt.telco_status = 'sent' and mt.num_media = 0) as sms_segments,
    sum(mt.num_segments) filter (where mt.telco_status = 'sent' and mt.num_media > 0) as mms_segments
  from sms.outbound_messages ob
  join sms.outbound_messages_routing as mr on mr.id = ob.id
  join sms.outbound_messages_telco as mt on mt.id = ob.id
  join sms.sending_locations sl on sl.id = mr.sending_location_id
  join sms.profiles p on p.id = sl.profile_id
  join sms.sending_accounts sa on sa.id = p.sending_account_id
  where true
    and p.client_id = client
    and mt.sent_at >= v_month_start
    and mt.sent_at < v_month_end
    and mt.original_created_at >= v_month_start - '1 day'::interval
    and mt.original_created_at < v_month_end + '1 day'::interval
  group by 1, 4;
end;
$$;

-- sms.backfill_pending_request_commitment_counts

CREATE FUNCTION sms.backfill_pending_request_commitment_counts() RETURNS void
    LANGUAGE sql
    AS $$
  with pending_number_commitment_counts as (
    select id as pending_number_request_id, coalesce(commitment_counts.commitment_count, 0) as commitment_count
    from sms.phone_number_requests
    left join (
      select count(*) as commitment_count, pending_number_request_id
      from sms.outbound_messages
      where stage = 'awaiting-number'::sms.outbound_message_stages
      group by pending_number_request_id
    ) as commitment_counts on sms.phone_number_requests.id = pending_number_request_id
    where fulfilled_at is null
  )
  update sms.phone_number_requests
  set commitment_count = pending_number_commitment_counts.commitment_count
  from pending_number_commitment_counts
  where pending_number_commitment_counts.pending_number_request_id = sms.phone_number_requests.id
$$;

COMMENT ON FUNCTION sms.backfill_pending_request_commitment_counts() IS '@omit';

-- billing.past_month_outbound_sms

CREATE VIEW billing.past_month_outbound_sms AS
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(outbound_messages.num_segments) FILTER (WHERE ((outbound_messages.stage = 'sent'::sms.outbound_message_stages) AND (outbound_messages.num_media = 0))) AS sms_segments,
    sum(outbound_messages.num_segments) FILTER (WHERE ((outbound_messages.stage = 'sent'::sms.outbound_message_stages) AND (outbound_messages.num_media > 0))) AS mms_segments,
    count(1) FILTER (WHERE ((outbound_messages.stage = 'queued'::sms.outbound_message_stages) OR (outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages))) AS queued_messages
   FROM ((((sms.outbound_messages
     JOIN sms.sending_locations ON ((sending_locations.id = outbound_messages.sending_location_id)))
     JOIN sms.profiles ON ((profiles.id = sending_locations.profile_id)))
     JOIN sms.sending_accounts ON ((sending_accounts.id = profiles.sending_account_id)))
     JOIN billing.clients ON ((clients.id = profiles.client_id)))
  WHERE ((outbound_messages.created_at >= (date_trunc('month'::text, now()) - '1 mon'::interval)) AND (outbound_messages.created_at < date_trunc('month'::text, now())))
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, sending_accounts.service;
