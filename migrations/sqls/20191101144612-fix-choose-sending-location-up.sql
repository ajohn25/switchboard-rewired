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
      select count(*) as commitment, from_number
      from sms.outbound_messages
      where created_at > now() - interval '36 hours'
        and sending_location_id in (
          select id from sending_location_options
        )
      group by sms.outbound_messages.from_number
      having count(*) < 200
    ),
    ordered_by_full_commitment_counts as (
      (
        select count(*) as commitment, from_number
        from sms.outbound_messages
        where from_number in (
          select from_number
          from phones_with_free_fresh_commitments
        )
        group by sms.outbound_messages.from_number
      )
      union (
        select commitment, from_number from phones_with_no_commitments
      )
      order by commitment
    )
    select from_number
    from ordered_by_full_commitment_counts
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