alter table sms.sending_locations enable row level security;

-- Drop previous policies
drop policy phone_numbers_policy on sms.all_phone_numbers;
drop policy sending_locations_policy on sms.sending_locations;

revoke insert, update, delete on sms.profiles from client;

alter table sms.profiles enable row level security;

create policy client_profile_policy
  on sms.profiles
  for select
  to client
  using ( sms.profiles.client_id = billing.current_client_id() );

revoke update, delete, truncate on sms.sending_locations from client;
grant insert, select on sms.sending_locations to client;

alter table sms.sending_locations enable row level security;

create policy client_sending_location_policy
  on sms.sending_locations
  for all
  to client
  using (exists ( select 1 from sms.profiles where id = sms.sending_locations.profile_id ) )
  with check (exists ( select 1 from sms.profiles where id = sms.sending_locations.profile_id ) );

alter table sms.all_phone_numbers enable row level security;

create policy client_phone_numbers_policy
  on sms.all_phone_numbers
  for all
  to client
  using ( exists ( select 1 from sms.sending_locations where id = sms.all_phone_numbers.sending_location_id ) )
  with check ( exists ( select 1 from sms.sending_locations where id = sms.all_phone_numbers.sending_location_id ) );
