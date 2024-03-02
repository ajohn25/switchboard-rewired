alter table sms.profiles disable row level security;
alter table sms.sending_locations disable row level security;
alter table sms.all_phone_numbers disable row level security;

drop policy client_profile_policy on sms.profiles;
drop policy client_sending_location_policy on sms.sending_locations;
drop policy client_phone_numbers_policy on sms.all_phone_numbers;

grant all on sms.sending_locations to client;
grant all on sms.profiles to client;

-- Note: this does not make sense (having policies without row level security enabled)
-- It's just done because the down migration should make things the previous database state
create policy phone_numbers_policy
  on sms.all_phone_numbers
  to client
  using (sending_location_id in (
    select sms.sending_locations.id
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.profiles.client_id = billing.current_client_id()
  ));

create policy sending_locations_policy
  on sms.sending_locations
  to client
  using (id in (
    select sms.sending_locations.id
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.profiles.client_id = billing.current_client_id()
  ));
