-- Update trigger security
-- -----------------------

create or replace function sms.tg__sending_locations__set_state_and_location() returns trigger as $$
declare
  v_state text;
  v_location point;
begin
  select state, location
  into v_state, v_location
  from geo.zip_locations
  where zip = NEW.center;

  if v_state is null or v_location is null then
    raise 'Could not find location record for zip code %. Please try another zip code.', NEW.center;
  end if;

  NEW.state := v_state;
  NEW.location := v_location;
  return NEW;
end;
$$ language plpgsql security definer;


create or replace function sms.tg__sending_locations_area_code__prefill() returns trigger as $$
declare
  v_area_codes text[];
begin
  select array_agg(distinct area_code)
  into v_area_codes
  from geo.zip_area_codes
  where geo.zip_area_codes.zip = NEW.center;

  -- Try the next closest zip code
  if coalesce(array_length(v_area_codes, 1), 0) = 0 then
    select array_agg(distinct geo.zip_area_codes.area_code)
    into v_area_codes
    from geo.zip_area_codes
    where zip = (
      select zip
      from geo.zip_locations
      where exists (
        select area_code
        from geo.zip_area_codes
        where geo.zip_area_codes.zip = geo.zip_locations.zip
      )
      order by location <-> NEW.location asc
      limit 1
    );
  end if;

  if coalesce(array_length(v_area_codes, 1), 0) = 0 then
    raise 'Could not find area codes for sending location with zip %', NEW.center;
  end if;

  NEW.area_codes = v_area_codes;

  return NEW;
end;
$$ language plpgsql security definer;