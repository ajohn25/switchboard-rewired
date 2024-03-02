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
