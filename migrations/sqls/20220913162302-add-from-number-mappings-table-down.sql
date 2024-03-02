DROP FUNCTION sms.process_grey_route_message;
CREATE FUNCTION sms.process_grey_route_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT '14 days'::interval) RETURNS json
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
  v_daily_contact_limit integer;
  v_throughput_interval interval;
  v_throughput_limit integer;
  v_result record;
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
    and (original_created_at > 'now'::timestamp - prev_mapping_validity_interval)
  order by original_created_at desc
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

    return row_to_json(v_result);
  end if;

  select daily_contact_limit, throughput_interval, throughput_limit
  into v_daily_contact_limit, v_throughput_interval, v_throughput_limit
  from sms.profiles
  where id = message.profile_id;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select sms.choose_existing_available_number(ARRAY[v_sending_location_id], v_daily_contact_limit, v_throughput_limit)
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

    return row_to_json(v_result);
  end if;

  -- If we're here, it means we need to buy a new number
  -- this could be because no numbers exist, or all are at or above capacity

  -- try to map it to existing pending number request
  select pending_number_request_id
  from sms.pending_number_request_capacity
  where commitment_count < v_daily_contact_limit
    and sms.pending_number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    insert into sms.outbound_messages_awaiting_from_number (
      id,
      original_created_at,
      to_number,
      pending_number_request_id,
      sending_location_id,
      decision_stage,
      processed_at,
      estimated_segments
    )
    values (
      message.id,
      message.created_at,
      message.to_number,
      v_pending_number_request_id,
      v_sending_location_id,
      'existing_pending_request',
      now(),
      message.estimated_segments
    )
    returning *
    into v_result;

    return row_to_json(v_result);
  end if;

  -- need to create phone_number_request - gotta pick an area code
  select sms.choose_area_code_for_sending_location(v_sending_location_id) into v_area_code;

  insert into sms.phone_number_requests (
    sending_location_id,
    area_code
  )
  values (
    v_sending_location_id,
    v_area_code
  )
  returning id
  into v_pending_number_request_id;

  insert into sms.outbound_messages_awaiting_from_number (
    id,
    original_created_at,
    to_number,
    pending_number_request_id,
    sending_location_id,
    decision_stage,
    processed_at,
    estimated_segments
  )
  values (
    message.id,
    message.created_at,
    message.to_number,
    v_pending_number_request_id,
    v_sending_location_id,
    'new_pending_request',
    now(),
    message.estimated_segments
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;


CREATE OR REPLACE FUNCTION sms.tg__phone_number_requests__fulfill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_throughput_interval interval;
  v_throughput_limit integer;
  v_sending_account_id uuid;
  v_capacity integer;
  v_purchasing_strategy sms.number_purchasing_strategy;
begin
  -- Create the phone number record
  insert into sms.phone_numbers (
    sending_location_id,
    phone_number
  )
  values (
    NEW.sending_location_id,
    NEW.phone_number
  );

  select sending_account_id, throughput_interval, throughput_limit
  from sms.profiles profiles
  join sms.sending_locations locations on locations.profile_id = profiles.id
  where locations.id = NEW.sending_location_id
  into v_sending_account_id, v_throughput_interval, v_throughput_limit;

  -- Update area code capacities
  with update_result as (
    update sms.area_code_capacities
    set capacity = capacity - 1
    where
      area_code = NEW.area_code
      and sending_account_id = v_sending_account_id
    returning capacity
  )
  select capacity
  from update_result
  into v_capacity;

  if ((v_capacity is not null) and (mod(v_capacity, 5) = 0)) then
    select purchasing_strategy
    from sms.sending_locations
    where id = NEW.sending_location_id
    into v_purchasing_strategy;

    if v_purchasing_strategy = 'exact-area-codes' then
      perform sms.refresh_one_area_code_capacity(NEW.area_code, v_sending_account_id);
    elsif v_purchasing_strategy = 'same-state-by-distance' then
      perform sms.queue_find_suitable_area_codes_refresh(NEW.sending_location_id);
    else
      raise exception 'Unknown purchasing strategy: %', v_purchasing_strategy;
    end if;
  end if;

  -- Process queued outbound messages
  with 
    deleted_afn as (
      delete from sms.outbound_messages_awaiting_from_number 
      where pending_number_request_id = NEW.id
      returning *
    ),
    interval_waits as (
      select
        id,
        to_number,
        original_created_at,
        sum(estimated_segments) over (partition by 1 order by original_created_at) as nth_segment
      from (
        select id, to_number, estimated_segments, original_created_at
        from deleted_afn
      ) all_messages
    )
    insert into sms.outbound_messages_routing 
      (
        id, 
        to_number, 
        estimated_segments, 
        decision_stage, 
        sending_location_id, 
        pending_number_request_id, 
        processed_at, 
        original_created_at,
        from_number, 
        stage, 
        first_from_to_pair_of_day, 
        send_after
      )
    select 
        afn.id, 
        afn.to_number, 
        estimated_segments, 
        decision_stage, 
        sending_location_id, 
        pending_number_request_id, 
        processed_at, 
        afn.original_created_at,
        NEW.phone_number as from_number,
        'queued' as stage,
        true as first_from_to_pair_of_day,
        now() + ((interval_waits.nth_segment / v_throughput_limit) * v_throughput_interval) as send_after
    from deleted_afn afn
    join interval_waits on interval_waits.id = afn.id;

  return NEW;
end;
$$;


alter table sms.outbound_messages_routing
  drop column profile_id;

alter table sms.outbound_messages_awaiting_from_number
  drop column profile_id;

drop view sms.active_from_number_mappings;
drop trigger _500_update_prev_mapping_after_routing on sms.outbound_messages_routing;
drop trigger _500_update_prev_mapping_after_inbound_received on sms.inbound_messages;
drop trigger _500_cordon_prev_mapping on sms.all_phone_numbers;
drop trigger _500_invalidate_prev_mapping on sms.all_phone_numbers;
drop table sms.from_number_mappings;

CREATE OR REPLACE FUNCTION sms.process_toll_free_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT '14 days'::interval) RETURNS json
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_channel sms.traffic_channel;
  v_sending_location_id uuid;
  v_from_number phone_number;
  v_result record;
begin
  select
      p.channel
    , sl.id
    , pn.phone_number
  from sms.phone_numbers pn
  join sms.sending_locations sl on sl.id = pn.sending_location_id
  join sms.profiles p on p.id = sl.profile_id
  where sl.profile_id = message.profile_id
  into
      v_channel
    , v_sending_location_id
    , v_from_number;

  if v_channel <> 'toll-free' then
    raise exception 'Profile is not toll-free channel: %', message.profile_id;
  end if;

  if v_sending_location_id is null or v_from_number is null then
    raise exception 'No toll-free number for profile: %', message.profile_id;
  end if;

  insert into sms.outbound_messages_routing (
      id
    , original_created_at
    , from_number
    , to_number
    , stage
    , sending_location_id
    , decision_stage
    , processed_at
  )
  values (
      message.id
    , message.created_at
    , v_from_number
    , message.to_number
    , 'queued'
    , v_sending_location_id
    , 'prev_mapping'
    , now()
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;