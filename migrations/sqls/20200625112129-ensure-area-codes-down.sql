create or replace function sms.tg__sending_locations_area_code__prefill() returns trigger as $$
declare
  v_area_codes text[];
begin
  select array_agg(area_code)
  from geo.zip_area_codes
  where geo.zip_area_codes.zip = NEW.center
  into v_area_codes;

  NEW.area_codes = v_area_codes;

  return NEW;
end;
$$ language plpgsql;

create or replace function sms.tg__sending_locations__set_state_and_location() returns trigger as $$
declare
  v_state text;
  v_location point;
begin
  select state
  from geo.zip_locations
  where zip = NEW.center
  into v_state;

  select location
  from geo.zip_locations
  where zip = NEW.center
  into v_location;

  NEW.state := v_state;
  NEW.location := v_location;
  return NEW;
end;
$$ language plpgsql;

drop trigger _500_choose_default_area_codes_on_sending_location on sms.sending_locations;
create trigger _500_choose_default_area_codes_on_sending_location
  before insert
  on sms.sending_locations
  for each row
  when (NEW.area_codes is null)
  execute procedure sms.tg__sending_locations_area_code__prefill();
