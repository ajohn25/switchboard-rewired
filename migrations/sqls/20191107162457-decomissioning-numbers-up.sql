-- Add decomission_at to sending locations
alter table sms.sending_locations add column decomissioned_at timestamp;

create index active_sending_locations_profile_id_idx on sms.sending_locations (profile_id) where decomissioned_at is null;
drop index sms.sending_location_profile_id_idx;

-- Modify phone numbers to have an id
alter table sms.phone_numbers drop constraint phone_numbers_pkey cascade;
alter table sms.phone_numbers add column id uuid default uuid_generate_v1mc() primary key;
alter table sms.phone_numbers add column sold_at timestamp;

drop index sms.phone_number_sending_location_id_idx;

create index active_phone_number_sending_location_idx on sms.phone_numbers (sending_location_id, phone_number) where released_at is null;

alter table sms.phone_numbers rename to all_phone_numbers;

comment on table sms.all_phone_numbers is E'@omit';

create view sms.phone_numbers as
  select phone_number, created_at, sending_location_id
  from sms.all_phone_numbers
  where released_at is null;

comment on view sms.phone_numbers is E'@omit';

-- Cascade decomissioned_at from sending location to numbers
create or replace function sms.cascade_sending_location_decomission() returns trigger as $$
begin
  update sms.all_phone_numbers
  set released_at = NEW.decomissioned_at
  where sms.all_phone_numbers.sending_location_id = NEW.id;

  return NEW;
end;
$$ language plpgsql;

create trigger _500_cascade_sending_location_decomission
  after update
  on sms.sending_locations
  for each row
  when (OLD.decomissioned_at is null and NEW.decomissioned_at is not null)
  execute procedure sms.cascade_sending_location_decomission();

create trigger _500_decomission_phone_number
  after update
  on sms.all_phone_numbers
  for each row
  when (OLD.released_at is null and NEW.released_at is not null)
  execute procedure trigger_job_with_sending_account_info('sell-number');

-- Remove on conflict do nothing remove phone number request fulfilling - no more unique constraint on phone numbers
create or replace function sms.tg__phone_number_requests__fulfill() returns trigger as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

  with interval_waits as (
    select
      id,
      sum(estimated_segments) over (partition by 1 order by created_at) as nth_segment
    from sms.outbound_messages
    where pending_number_request_id = NEW.id
      and sms.outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages
  )
  update sms.outbound_messages
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages,
      send_after = now() + (interval_waits.nth_segment * interval '10 seconds')
  from interval_waits
  where interval_waits.id = sms.outbound_messages.id;
 
  return NEW;
end;
$$ language plpgsql;

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
  with
    sending_location_options as (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
        and sms.sending_locations.decomissioned_at is null
    ),
    phones_with_no_commitments as (
      select 0 as commitment, phone_number as from_number
      from sms.phone_numbers
      where sending_location_id in (
          select id from sending_location_options
        )
        and not exists (
        select 1
        from sms.outbound_messages
        where from_number = sms.phone_numbers.phone_number
      )
    ),
    phones_with_free_fresh_commitments as (
      select count(distinct to_number) as commitment, from_number
      from sms.outbound_messages
      where created_at > now() - interval '36 hours'
        and sending_location_id in (
          select id from sending_location_options
        )
      group by sms.outbound_messages.from_number
      having count(distinct to_number) < 200
    )
    select from_number
    from ( select * from phones_with_free_fresh_commitments union select * from phones_with_no_commitments ) as all_phones
    order by commitment
    limit 1
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

comment on function sms.choose_sending_location_for_contact is E'@omit';