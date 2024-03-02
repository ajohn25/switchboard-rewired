create or replace function sms.choose_sending_location_for_contact(contact_zip_code zip_code, profile_id uuid) returns uuid as $$
declare
  v_sending_location_id uuid;
  v_from_number phone_number;
  v_contact_state text;
  v_contact_location point;
begin
  select state
  from geo.zip_locations
  where zip = contact_zip_code
  into v_contact_state;

  select location
  from geo.zip_locations
  where zip = contact_zip_code
  into v_contact_location;

  if v_contact_location is not null then
  -- Find the closest one in the same state
    select id
    from sms.sending_locations
    where state = v_contact_state
      and sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
      and decomissioned_at is null
    order by location <-> v_contact_location asc
    limit 1
    into v_sending_location_id;

    if v_sending_location_id is not null then
      return v_sending_location_id;
    end if;

    -- Find the next closest one
    select id
    from sms.sending_locations
    where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
      and decomissioned_at is null
    order by location <-> v_contact_location asc
    limit 1
    into v_sending_location_id;

    if v_sending_location_id is not null then
      return v_sending_location_id;
    end if;
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

