create table geo.zip_locations (
  zip text primary key,
  state text not null,
  location point not null
);

-- This is just for development - will be overwritten in production
insert into geo.zip_locations (zip, state, location)
values
  ('10001', 'NY', '(40.75061,-73.99716)'),
  ('10004', 'NY', '(40.69465,-74.02106)'),
  ('10005', 'NY', '(40.70616,-74.00907)'),
  ('10012', 'NY', '(40.72563,-73.99803)'),
  ('10020', 'NY', '(40.75906,-73.98026)'),
  ('10029', 'NY', '(40.79173,-73.94396)'),
  ('11104', 'NY', '(40.7446,-73.92027)'),
  ('11205', 'NY', '(40.69468,-73.96613)'),
  ('11212', 'NY', '(40.66293,-73.91303)'),
  ('11238', 'NY', '(40.67913,-73.96384)'),
  ('11373', 'NY', '(40.73886,-73.87858)'),
  ('07030', 'NJ', '(40.74524,-74.03217)'), -- Hoboken, NJ
  ('08540', 'NJ', '(40.3633,-74.65568)');  -- Princeton, NJ

alter table sms.sending_locations add column state text;
alter table sms.sending_locations add column location point;

create function sms.tg__sending_locations__set_state_and_location() returns trigger as $$
declare
  v_state text;
  v_location point;
begin
  select state
  from geo.zip_locations
  where zip = NEW.center
  into v_state;

  select v_location
  from geo.zip_locations
  where zip = NEW.center
  into v_location;

  NEW.state := v_state;
  NEW.location := v_location;
  return NEW;
end;
$$ language plpgsql;

create trigger _200_set_state_and_location_before_insert
  before insert
  on sms.sending_locations
  for each row
  execute procedure sms.tg__sending_locations__set_state_and_location();

create trigger _200_set_state_and_location_before_update
  before update
  on sms.sending_locations
  for each row
  when (NEW.center <> OLD.center)
  execute procedure sms.tg__sending_locations__set_state_and_location();

-- Used for backfilling
create function sms.reset_sending_location_state_and_locations() returns void as $$
  update sms.sending_locations
  set
    state = geo.zip_locations.state,
    location = geo.zip_locations.location
  from geo.zip_locations
  where sms.sending_locations.center = geo.zip_locations.zip;
$$ language sql;

drop index sms.active_sending_locations_profile_id_idx;
create index active_sending_locations_profile_id_idx on sms.sending_locations (profile_id, state) where decomissioned_at is null;

-- This is likely the best index for the query we're running
-- according to https://www.2ndquadrant.com/en/blog/postgresql-12-implementing-k-nearest-neighbor-space-partitioned-generalized-search-tree-indexes/
create index sending_location_distance_search_idx on sms.sending_locations using spgist(location);

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
    order by location <-> v_contact_location desc
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
    order by location <-> v_contact_location desc
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
