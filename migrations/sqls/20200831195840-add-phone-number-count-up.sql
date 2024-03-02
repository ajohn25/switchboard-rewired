create or replace function
sms.sending_locations_active_phone_number_count(sl sms.sending_locations)
returns bigint as $$ 
  select count(*)
  from sms.phone_numbers
  where sending_location_id = sl.id
$$ language sql stable strict security definer;

