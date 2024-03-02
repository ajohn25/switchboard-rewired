-- profile deletion is used in tests, so on delete cascade is necessary
-- for new foreign keys
create table sms.from_number_mappings (
  profile_id uuid references sms.profiles (id) on delete cascade,
  to_number text,
  from_number text,
  last_used_at timestamptz not null,
  sending_location_id uuid not null,
  cordoned_at timestamptz,
  invalidated_at timestamptz
);

create view sms.active_from_number_mappings as
  select *
  from sms.from_number_mappings
  where invalidated_at is null;

-- We need to add profile_id to outbound_messages_routing and outbound_messages_awaiting_from_number
-- in order to more easily update the prev mappings
-- it will also make subsequent work easier
alter table sms.outbound_messages_routing
  add column profile_id uuid references sms.profiles (id) on delete cascade;

alter table sms.outbound_messages_awaiting_from_number
  add column profile_id uuid references sms.profiles (id) on delete cascade;

-- When we move things from awaiting_from_number to routing, we need to carry over profile_id
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
        send_after,
        profile_id
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
        now() + ((interval_waits.nth_segment / v_throughput_limit) * v_throughput_interval) as send_after,
        profile_id
    from deleted_afn afn
    join interval_waits on interval_waits.id = afn.id;

  return NEW;
end;
$$;


create unique index prev_mapping_idx 
  on sms.from_number_mappings (to_number, profile_id) 
  where (invalidated_at is null);

create index on sms.from_number_mappings (from_number) where (invalidated_at is not null);

-- Handles inserts in from_number_mappings after routing
create or replace function sms.update_from_number_mappings_after_routing() returns trigger as $$
begin
  if NEW.profile_id is null then
    raise 'Message inserted into routing without a profile_id - not allowed';
  end if;
  
  insert into sms.from_number_mappings (profile_id, to_number, from_number, last_used_at, sending_location_id)
  values (NEW.profile_id, NEW.to_number, NEW.from_number, NEW.original_created_at, NEW.sending_location_id)
  on conflict (to_number, profile_id) where invalidated_at is null
  do update
  set last_used_at = NEW.original_created_at;

  return NEW;
end;
$$ language plpgsql;

create trigger _500_update_prev_mapping_after_routing
  after insert on sms.outbound_messages_routing
  for each row
  when (NEW.decision_stage <> 'toll_free')
  execute procedure sms.update_from_number_mappings_after_routing();

-- Handles inserts in from_number_mappings after an inbound message is received
create or replace function sms.update_from_number_mappings_after_inbound_received() returns trigger as $$
begin
  -- This is different from the routing handler since we don't want this to do an insert, just update
  -- last_used_at
  -- If there's an inbound message to an invalidated prev mapping, we don't want that to re-validate
  -- the mapping
  update sms.from_number_mappings
  set last_used_at = greatest(last_used_at, NEW.received_at)
  where invalidated_at is null
    and to_number = NEW.from_number 
    and from_number = NEW.to_number
    and profile_id = (
      select profile_id
      from sms.sending_locations
      where sms.sending_locations.id = NEW.sending_location_id
    );

  return NEW;
end;
$$ language plpgsql;

create trigger _500_update_prev_mapping_after_inbound_received
  after insert on sms.inbound_messages
  for each row
  execute procedure sms.update_from_number_mappings_after_inbound_received();

-- Handles cordon updates of previous mapping pairings
create or replace function sms.cordon_from_number_mappings() returns trigger as $$
begin
  update sms.from_number_mappings 
  set cordoned_at = NEW.cordoned_at
  where from_number = NEW.phone_number
    and invalidated_at is null;

  return NEW;
end;
$$ language plpgsql;

create trigger _500_cordon_prev_mapping
  after update on sms.all_phone_numbers
  for each row
  when (NEW.cordoned_at is distinct from OLD.cordoned_at)
  execute procedure sms.cordon_from_number_mappings();

-- Handles invalidation of previous mapping pairings
create or replace function sms.invalidate_from_number_mappings() returns trigger as $$
begin
  update sms.from_number_mappings 
  set invalidated_at = NEW.released_at
  where from_number = NEW.phone_number
    and invalidated_at is null;

  return NEW;
end;
$$ language plpgsql;

create trigger _500_invalidate_prev_mapping
  after update on sms.all_phone_numbers
  for each row
  when (NEW.released_at is distinct from OLD.released_at)
  execute procedure sms.invalidate_from_number_mappings();


DROP FUNCTION sms.process_grey_route_message;
CREATE FUNCTION sms.process_grey_route_message(message sms.outbound_messages) RETURNS json
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
  select from_number, last_used_at, sending_location_id
  from sms.active_from_number_mappings
  where to_number = message.to_number
    and profile_id = message.profile_id
    and (
      cordoned_at is null 
      or cordoned_at > now() - interval '3 days'
      or last_used_at > now() - interval '3 days'
    )
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
      first_from_to_pair_of_day,
      profile_id
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
      v_prev_mapping_first_send_of_day,
      message.profile_id
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
      sending_location_id,
      profile_id
    )
    values (
      message.id,
      message.created_at,
      v_from_number,
      message.to_number,
      'queued',
      'existing_phone_number',
      now(),
      v_sending_location_id,
      message.profile_id
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
      estimated_segments,
      profile_id
    )
    values (
      message.id,
      message.created_at,
      message.to_number,
      v_pending_number_request_id,
      v_sending_location_id,
      'existing_pending_request',
      now(),
      message.estimated_segments,
      message.profile_id
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
    estimated_segments,
    profile_id
  )
  values (
    message.id,
    message.created_at,
    message.to_number,
    v_pending_number_request_id,
    v_sending_location_id,
    'new_pending_request',
    now(),
    message.estimated_segments,
    message.profile_id
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;
comment on function sms.process_grey_route_message is '@omit';

-- toll free needs to use a new decision stage, and also include profile_id
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
    , profile_id
  )
  values (
      message.id
    , message.created_at
    , v_from_number
    , message.to_number
    , 'queued'
    , v_sending_location_id
    , 'toll_free'
    , now()
    , message.profile_id
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;

comment on function sms.process_toll_free_message is '@omit';

-- toll free needs to use a new decision stage, and also include profile_id
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
    , profile_id
  )
  values (
      message.id
    , message.created_at
    , v_from_number
    , message.to_number
    , 'queued'
    , v_sending_location_id
    , 'toll_free'
    , now()
    , message.profile_id
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;

-- I benchmarked this and it took around 13 seconds to do the select (returning around 5 million rows), 
-- so it'd take under a minute or two to do the insert
-- I think that's fine to do as part of the same transaction as the above, as long as this is deployed off hours
insert into sms.from_number_mappings (profile_id, from_number, to_number, sending_location_id, cordoned_at, invalidated_at, last_used_at)
select distinct on (sl.profile_id, m.from_number, m.to_number) sl.profile_id, m.from_number, m.to_number, m.sending_location_id, pn.cordoned_at, pn.released_at, m.original_created_at
from sms.outbound_messages_routing m
join sms.sending_locations sl on sl.id = m.sending_location_id
join sms.all_phone_numbers pn on pn.phone_number = m.from_number and pn.sending_location_id = m.sending_location_id
where original_created_at > now() - interval '2 weeks'
order by sl.profile_id, m.from_number, m.to_number, m.original_created_at desc
on conflict (to_number, profile_id) where invalidated_at is null
do nothing;