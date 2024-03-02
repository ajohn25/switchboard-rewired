alter table sms.outbound_messages add column processed_at timestamp;

-- Backfill for processed at
-- update sms.outbound_messages
-- set processed_at = created_at
-- where stage <> 'processing';

create table sms.fresh_phone_commitments (
  phone_number phone_number,
  truncated_day timestamp,
  commitment integer default 0,
  primary key (truncated_day, phone_number)
);

create index commitment_bucket_under_threshold on sms.fresh_phone_commitments (commitment) where (commitment <= 200);

-- Function to update the bucket values
-- Assumes table has NEW.from_number
create or replace function sms.increment_commitment_bucket_if_unique() returns trigger as $$
declare
  v_already_recorded boolean;
begin
  select exists (
    select 1
    from sms.outbound_messages
    where sms.outbound_messages.from_number = NEW.from_number
      and sms.outbound_messages.to_number = NEW.to_number
      and sms.outbound_messages.processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu') 
      and sms.outbound_messages.processed_at < NEW.processed_at
  )
  into v_already_recorded;

  if not v_already_recorded then
    insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment)
    values (NEW.from_number, date_trunc('day', current_timestamp), 1)
    on conflict (truncated_day, phone_number)
    do update
    set commitment = sms.fresh_phone_commitments.commitment + 1;
  end if;

  return NEW;
end;
$$ language plpgsql volatile strict;

create trigger _500_increment_commitment_bucket_after_update
  after update
  on sms.outbound_messages
  for each row
  when (OLD.from_number is null and NEW.from_number is not null)
  execute procedure sms.increment_commitment_bucket_if_unique();

create trigger _500_increment_commitment_bucket_after_insert
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.from_number is not null)
  execute procedure sms.increment_commitment_bucket_if_unique();

-- Should be run once after the table is created
create or replace function sms.backfill_commitment_buckets() returns void as $$
  with values_to_write as (
    select from_number, date_trunc('day', processed_at) as truncated_day, count(distinct to_number) as commitment
    from sms.outbound_messages
    where created_at > now() - interval '2 days'  -- can safely limit created_at since only those are relevant buckets
      and processed_at is not null
      and from_number is not null
    group by 1, 2
  )
  insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment)
  select from_number as phone_number, truncated_day, commitment
  from values_to_write
  on conflict (truncated_day, phone_number)
  do update
  set commitment = excluded.commitment
$$ language sql;

create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns phone_number as $$
  with phones_with_no_commitments as (
    select 0 as commitment, phone_number as from_number
    from sms.phone_numbers
    where sending_location_id = ANY(sending_location_id_options)
      and not exists (
        select 1
        from sms.outbound_messages
        where from_number = sms.phone_numbers.phone_number
      )
  ),
  phones_with_free_fresh_commitments as (
    select commitment, phone_number as from_number
    from sms.fresh_phone_commitments
    where commitment <= 200
      and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
      and phone_number in (
        select phone_number
        from sms.phone_numbers
        where sms.phone_numbers.sending_location_id = ANY(sending_location_id_options)
      )
  ),
  phones_with_overloaded_queues as (
    select sum(estimated_segments) as commitment, from_number
    from sms.outbound_messages
    where processed_at > now() - interval '1 minute'
      and stage <> 'awaiting-number'
      and from_number in (
        select from_number from phones_with_free_fresh_commitments
      )
    group by sms.outbound_messages.from_number
    having sum(estimated_segments) > 6
  )
  select from_number
  from ( select * from phones_with_free_fresh_commitments union select * from phones_with_no_commitments ) as all_phones
  where from_number not in (
    select from_number
    from phones_with_overloaded_queues
  )
  order by commitment
  limit 1
$$ language sql;


create or replace function sms.process_message (message sms.outbound_messages) returns sms.outbound_messages as $$
declare
  v_sending_location_id uuid;
  v_prev_from_number phone_number;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number
  from sms.outbound_messages
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages.from_number
    )
  order by created_at desc
  limit 1
  into v_prev_from_number;

  if v_prev_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where phone_number = v_prev_from_number
    into v_sending_location_id; 

    update sms.outbound_messages
    set from_number = v_prev_from_number,
        stage = 'queued',
        sending_location_id = v_sending_location_id,
        decision_stage = 'prev_mapping',
        processed_at = now()
    where id = message.id
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
    update sms.outbound_messages
    set from_number = v_from_number,
        stage = 'queued',
        decision_stage = 'existing_phone_number',
        processed_at = now(),
        sending_location_id = v_sending_location_id
    where id = message.id
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
    and sms.pending_Number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    update sms.outbound_messages
    set pending_number_request_id = v_pending_number_request_id,
        stage = 'awaiting-number',
        sending_location_id = v_sending_location_id,
        decision_stage = 'existing_pending_request',
        processed_at = now()
    where id = message.id
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

  update sms.outbound_messages
  set pending_number_request_id = v_pending_number_request_id,
      stage = 'awaiting-number',
      sending_location_id = v_sending_location_id,
      decision_stage = 'new_pending_request',
      processed_at = now()
  where id = message.id
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

create or replace function sms.choose_sending_location_for_contact(contact_zip_code zip_code, profile_id uuid) returns uuid as $$
declare
  v_sending_location_id uuid;
  v_from_number phone_number;
  v_contact_state text;
begin
  select zip1_state
  from geo.zip_proximity
  where zip1 = contact_zip_code
  into v_contact_state;

  -- Try to find a close one in the same state
  select id
  from sms.sending_locations
  join (
    select zip1, min(distance_in_miles) as distance
    from geo.zip_proximity
    where zip1_state = v_contact_state
      and zip2_state = v_contact_state
      and zip2 = contact_zip_code
    group by zip1
  ) as zp on zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  order by distance asc
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Try to find anyone in the same state
  select id
  from sms.sending_locations
  join geo.zip_proximity on geo.zip_proximity.zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
    and geo.zip_proximity.zip1_state = v_contact_state
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Try to find a close one
  select id
  from sms.sending_locations
  join ( 
    select zip1, min(distance_in_miles) as distance
    from geo.zip_proximity
    where zip2 = contact_zip_code
    group by zip1
  ) as zp on zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  order by distance asc
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Pick one with available phone numbers
  select sms.choose_existing_available_number(array_agg(id))
  from sms.sending_locations
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  into v_from_number;

  if v_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where sms.phone_numbers.phone_number = v_from_number
    into v_sending_location_id;

    return v_sending_location_id;
  end if;

  -- Pick a random one
  select id
  from sms.sending_locations
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  order by random()
  limit 1
  into v_sending_location_id;

  return v_sending_location_id;
end;
$$ language plpgsql;

drop index sms.phone_number_capacity_idx;
create index outbound_messages_phone_number_overloaded_idx on sms.outbound_messages (from_number, processed_at desc);

