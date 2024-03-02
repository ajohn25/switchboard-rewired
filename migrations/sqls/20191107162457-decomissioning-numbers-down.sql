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
  order by random()
  limit 1
  into v_sending_location_id;

  return v_sending_location_id;
end;
$$ language plpgsql;

comment on function sms.choose_sending_location_for_contact is E'@omit';

drop trigger _500_cascade_sending_location_decomission on sms.sending_locations;
drop trigger _500_decomission_phone_number on sms.all_phone_numbers;
drop function sms.cascade_sending_location_decomission;

-- Drop decomissioned_at from sms.sending_locations
create index sending_location_profile_id_idx on sms.sending_locations (profile_id);
drop index sms.active_sending_locations_profile_id_idx;

alter table sms.sending_locations drop column decomissioned_at;

-- Drop phone numbers id
drop view sms.phone_numbers;
alter table sms.all_phone_numbers rename to phone_numbers;

comment on table sms.phone_numbers is E'@omit';

alter table sms.phone_numbers drop column id;
alter table sms.phone_numbers drop column sold_at;
alter table sms.phone_numbers add primary key (phone_number);

drop index sms.active_phone_number_sending_location_idx;
create index phone_number_sending_location_idx on sms.phone_numbers (sending_location_id);

-- Reinstate on conflict do nothing constraint on phone numbers
create or replace function sms.tg__phone_number_requests__fulfill() returns trigger as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number)
  on conflict (phone_number) do nothing;

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
