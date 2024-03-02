CREATE OR REPLACE FUNCTION sms.increment_commitment_bucket_if_unique() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
declare
  v_already_recorded boolean;
begin
  insert into sms.fresh_phone_commitments (phone_number, commitment, sending_location_id)
  values (NEW.from_number, 1, NEW.sending_location_id)
  on conflict (phone_number)
  do update
  set commitment = sms.fresh_phone_commitments.commitment + 1;

  return NEW;
end;
$$;

CREATE OR REPLACE FUNCTION sms.backfill_commitment_buckets() RETURNS void
    LANGUAGE sql
    AS $$
  with values_to_write as (
    select
      from_number,
      count(distinct to_number) as commitment,
      sending_location_id
    from sms.outbound_messages
    where processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
          -- can safely limit created_at since only those are relevant buckets
      and processed_at is not null
      and from_number is not null
      and stage <> 'awaiting-number'
    group by 1, 3
  )
  insert into sms.fresh_phone_commitments (phone_number, commitment, sending_location_id)
  select from_number as phone_number, commitment, sending_location_id
  from values_to_write
  on conflict (phone_number)
  do update
  set commitment = excluded.commitment
$$;

CREATE OR REPLACE FUNCTION sms.process_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT NULL::interval) RETURNS sms.outbound_messages_routing
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_contact_zip_code public.zip_code;
  v_sending_location_id uuid;
  v_prev_mapping_from_number phone_number;
  v_prev_mapping_created_at timestamp;
  v_prev_mapping_first_send_of_day boolean;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages_routing;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  -- Note - right now, if prev_mapping_validity_interval is null, this searches over all time chunks
  -- we need to benchmark this in production to see what the chunk search penalty is
  select from_number, processed_at, sending_location_id
  from sms.outbound_messages_routing
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages_routing.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages_routing.from_number
        and (
          sms.phone_numbers.cordoned_at is null
          or
          sms.phone_numbers.cordoned_at > now() - interval '3 days'
        )
    )
    and (prev_mapping_validity_interval is null or processed_at > now() - prev_mapping_validity_interval)
  order by processed_at desc
  limit 1
  into v_prev_mapping_from_number, v_prev_mapping_created_at, v_sending_location_id;

  if v_prev_mapping_from_number is not null then
    select
      v_prev_mapping_created_at <
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    into v_prev_mapping_first_send_of_day;

    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      from_number,
      to_number,
      stage,
      sending_location_id,
      decision_stage,
      processed_at,
      first_from_to_pair_of_day
    )
    values (
      message.id,
      message.created_at,
      v_prev_mapping_from_number,
      message.to_number,
      'queued',
      v_sending_location_id,
      'prev_mapping',
      now(),
      v_prev_mapping_first_send_of_day
    )
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select sms.choose_existing_available_number(ARRAY[v_sending_location_id])
  into v_from_number;

  if v_from_number is not null then
    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      from_number,
      to_number,
      stage,
      decision_stage,
      processed_at,
      sending_location_id
    )
    values (
      message.id,
      message.created_at,
      v_from_number,
      message.to_number,
      'queued',
      'existing_phone_number',
      now(),
      v_sending_location_id
    )
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it means we need to buy a new number
  -- this could be because no numbers exist, or all are at or above capacity

  -- try to map it to existing pending number request
  select pending_number_request_id
  from sms.pending_number_request_capacity
  where commitment_count < 200
    and sms.pending_number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      to_number,
      pending_number_request_id,
      stage,
      sending_location_id,
      decision_stage,
      processed_at
    )
    values (
      message.id,
      message.created_at,
      message.to_number,
      v_pending_number_request_id,
      'awaiting-number',
      v_sending_location_id,
      'existing_pending_request',
      now()
    )
    returning *
    into v_result;

    return v_result;
  end if;

  -- need to create phone_number_request - gotta pick an area code
  select sms.choose_area_code_for_sending_location(v_sending_location_id) into v_area_code;

  insert into sms.phone_number_requests (sending_location_id, area_code)
  values (v_sending_location_id, v_area_code)
  returning id
  into v_pending_number_request_id;

  insert into sms.outbound_messages_routing (
    id,
    original_created_at,
    to_number,
    pending_number_request_id,
    stage,
    sending_location_id,
    decision_stage,
    processed_at
  )
  values (
    message.id,
    message.created_at,
    message.to_number,
    v_pending_number_request_id,
    'awaiting-number',
    v_sending_location_id,
    'new_pending_request',
    now()
  )
  returning *
  into v_result;

  return v_result;
end;
$$;

create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns public.phone_number
  language plpgsql
  as $$
declare
  v_phone_number phone_number;
begin
  -- First, check for numbers not texted today
  select phone_number
  from sms.phone_numbers
  where sending_location_id = ANY(sending_location_id_options)
    and cordoned_at is null
    and not exists (
      select 1
      from sms.fresh_phone_commitments
      where sms.fresh_phone_commitments.phone_number = sms.phone_numbers.phone_number
    )
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  -- Next, find the one least texted not currently overloaded and not cordoned
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and commitment <= 200
    and phone_number not in (
      select from_number
      from sms.outbound_messages_routing
      where processed_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
        and original_created_at > date_trunc('day', now())
      group by sms.outbound_messages_routing.from_number
      having sum(estimated_segments) > 6
    )
    -- Check that this phone number isn't cordoned
    and not exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.phone_number = sms.fresh_phone_commitments.phone_number
        and not (cordoned_at is null)
    )
  order by commitment
  for update skip locked
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$;


create or replace function sms.tg__phone_number_requests__fulfill() returns trigger
  language plpgsql
  as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

  with interval_waits as (
    select
      id,
      to_number,
      original_created_at,
      sum(estimated_segments) over (partition by 1 order by original_created_at) as nth_segment
    from (
      select id, to_number, estimated_segments, original_created_at
      from sms.outbound_messages_routing
      where pending_number_request_id = NEW.id
        and sms.outbound_messages_routing.stage = 'awaiting-number'::sms.outbound_message_stages
        and sms.outbound_messages_routing.original_created_at > NEW.created_at - interval '1 day'
    ) all_messages
  )
  update sms.outbound_messages_routing
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages,
      send_after = now() + (interval_waits.nth_segment * interval '10 seconds')
  from interval_waits
  where
    -- join on indexed to_number
    interval_waits.to_number = sms.outbound_messages_routing.to_number
    -- then filter by un-indexed sms.outbound_messages_routing.id
    and interval_waits.id = sms.outbound_messages_routing.id
    and interval_waits.original_created_at = sms.outbound_messages_routing.original_created_at;

  return NEW;
end;
$$;

drop view sms.phone_numbers;
create or replace view sms.phone_numbers as
  select
    all_phone_numbers.phone_number,
    all_phone_numbers.created_at,
    all_phone_numbers.sending_location_id,
    all_phone_numbers.cordoned_at
  from sms.all_phone_numbers
  where all_phone_numbers.released_at is null;

comment on view sms.phone_numbers is '@omit';

drop view sms.pending_number_request_capacity;
create or replace view sms.pending_number_request_capacity as
 select phone_number_requests.id as pending_number_request_id,
    phone_number_requests.commitment_count
   from sms.phone_number_requests
  where (phone_number_requests.fulfilled_at is null);

comment on view sms.pending_number_request_capacity is '@omit';

alter table sms.phone_number_requests
  drop column daily_contact_limit,
  drop column throughput_interval,
  drop column throughput_limit;

alter table sms.fresh_phone_commitments
  drop column daily_contact_limit,
  drop column throughput_interval,
  drop column throughput_limit;

alter table sms.all_phone_numbers
  drop column daily_contact_limit,
  drop column throughput_interval,
  drop column throughput_limit;

alter table sms.profiles
  drop column daily_contact_limit,
  drop column throughput_interval,
  drop column throughput_limit;
