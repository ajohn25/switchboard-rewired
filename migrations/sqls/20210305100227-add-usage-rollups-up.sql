--- Create usage rollup tables
-- ------------------------------------------------------------

create table billing.lrn_usage_rollups ( id uuid primary key default uuid_generate_v1mc(), client_id uuid not null references billing.clients(id), created_at timestamp default now(), period_start timestamp without time zone not null, period_end timestamp without time zone not null, stripe_usage_record_id text, lrn integer not null);


create unique index lrn_usage_rollups_lookup on billing.lrn_usage_rollups (client_id, period_start, period_end);


create table billing.messaging_usage_rollups ( id uuid primary key default uuid_generate_v1mc(), profile_id uuid not null references sms.profiles(id), created_at timestamp default now(), period_start timestamp without time zone not null, period_end timestamp without time zone not null, stripe_usage_record_id text, outbound_sms_messages integer not null, outbound_sms_segments integer not null, outbound_mms_messages integer not null, outbound_mms_segments integer not null, inbound_sms_messages integer not null, inbound_sms_segments integer not null, inbound_mms_messages integer not null, inbound_mms_segments integer not null);


create unique index messaging_usage_rollups_lookup on billing.messaging_usage_rollups (profile_id, period_start, period_end);

-- Add sent_at column to telco table
-- ------------------------------------------------------------
 -- Add the column

-- Backfill with routing's processed_at
create or replace function billing.backfill_telco_sent_at_around(fire_date timestamp) returns bigint
language sql
as $$ 
  with update_result as (
    update sms.outbound_messages_telco mt
    set sent_at = mr.processed_at
    from sms.outbound_messages_routing mr
    where mr.id = mt.id
      and mr.processed_at >= date_trunc('hour', fire_date - '1 hour'::interval)
      and mr.processed_at < date_trunc('hour', fire_date)
      and mr.stage <> 'awaiting-number'
    returning 1
  )
  select count(*)
  from update_result
$$;


-- Set default
alter table sms.outbound_messages_telco
alter column sent_at
set default now();

-- Index the column - should be run concurrently in production
create index outbound_messages_telco_sent_at on sms.outbound_messages_telco (sent_at) where (sent_at is not null);

-- Add received_at index to inbound messages
-- Should be run concurrently in production
-- ------------------------------------------------------------
create index inbound_messages_received_at on sms.inbound_messages (received_at);

-- Create function for generating rollups
create or replace function billing.generate_usage_rollups(fire_date timestamp) returns void language plpgsql as $$
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

-- Update legacy outbound message usage function to use new index
-- --------------------------------------------------------------

drop function billing.outbound_message_usage(uuid, timestamp with time zone);


create function billing.outbound_message_usage(client uuid, month timestamp with time zone) returns table(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, sms_segments bigint, mms_segments bigint) language plpgsql as $$
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


-- Full backfill procedure
create or replace procedure billing.incremental_rollup_backfill_from(start_date timestamp, end_date timestamp) 
language plpgsql 
as $$
declare
  v_fire_date timestamp;
  v_count_sent bigint;
begin
  v_fire_date := start_date;

  while v_fire_date <= end_date loop 
    raise notice 'Backfilling around %', v_fire_date;

    select billing.backfill_telco_sent_at_around(v_fire_date)
    into v_count_sent;

    perform billing.generate_usage_rollups(v_fire_date);

    raise notice 'Backfilled billing info for % outbound messages', v_count_sent;

    commit;

    v_fire_date := v_fire_date + '1 hour'::interval;
  end loop;
end
$$;
