-- Replace function body
-- ----------------------------

CREATE OR REPLACE FUNCTION billing.generate_usage_rollups(fire_date timestamp without time zone) RETURNS void
    LANGUAGE plpgsql
    AS $$
declare
  v_period_end timestamp;
  v_period_start timestamp;
begin
  select
    date_trunc('hour', fire_date) - '1 hour'::interval,
    date_trunc('hour', fire_date)
  into v_period_start, v_period_end;

  -- LRN
  insert into billing.lrn_usage_rollups (client_id, period_start, period_end, lrn)
  select
    lrn_usage.client_id,
    v_period_start,
    v_period_end,
    count(distinct lrn_usage.phone_number)
  from lookup.accesses lrn_usage
  where
    lrn_usage.accessed_at >= v_period_start
    and lrn_usage.accessed_at < v_period_end
    and not exists (
      select 1 from lookup.accesses previous_usage
      where
        previous_usage.accessed_at < v_period_start
        and previous_usage.phone_number = lrn_usage.phone_number
    )
  group by lrn_usage.client_id
  on conflict (client_id, period_start, period_end)
  do nothing;

  -- Messaging
  insert into billing.messaging_usage_rollups (
    profile_id,
    period_start,
    period_end,
    outbound_sms_messages,
    outbound_sms_segments,
    outbound_mms_messages,
    outbound_mms_segments,
    inbound_sms_messages,
    inbound_sms_segments,
    inbound_mms_messages,
    inbound_mms_segments
  )
  select
    coalesce(outbound.profile_id, inbound.profile_id),
    v_period_start,
    v_period_end,
    coalesce(outbound.sms_messages, 0),
    coalesce(outbound.sms_segments, 0),
    coalesce(outbound.mms_messages, 0),
    coalesce(outbound.mms_segments, 0),
    coalesce(inbound.sms_messages, 0),
    coalesce(inbound.sms_segments, 0),
    coalesce(inbound.mms_messages, 0),
    coalesce(inbound.mms_segments, 0)
  from (
    -- gather usage post-split
    select
      ob.profile_id,
      count(*) filter (where mt.num_media = 0) as sms_messages,
      sum(mt.num_segments) filter (where mt.num_media = 0) as sms_segments,
      count(*) filter (where mt.num_media > 0) as mms_messages,
      sum(mt.num_segments) filter (where mt.num_media > 0) as mms_segments
    from sms.outbound_messages ob
    join sms.outbound_messages_telco as mt on mt.id = ob.id
    where true
      and mt.sent_at >= v_period_start
      and mt.sent_at < v_period_end
      and mt.original_created_at >= v_period_start - '1 day'::interval
      and mt.original_created_at < v_period_end + '1 day'::interval
      and ob.created_at >= v_period_start - '1 day'::interval
      and ob.created_at < v_period_end + '1 day'::interval
    group by 1
  ) outbound
  full outer join (
    select
      sl.profile_id,
      count(*) filter (where num_media = 0) as sms_messages,
      sum(num_segments) filter (where num_media = 0) as sms_segments,
      count(*) filter (where num_media > 0) as mms_messages,
      sum(num_segments) filter (where num_media > 0) as mms_segments
    from sms.inbound_messages im
    join sms.sending_locations sl
      on sl.id = im.sending_location_id
    where true
      and received_at >= v_period_start
      and received_at < v_period_end
    group by 1
  ) inbound
    on outbound.profile_id = inbound.profile_id
  on conflict (profile_id, period_start, period_end)
  do nothing;
end;
$$;
