create view sms.sending_location_capacities as
  select
    sending_location_area_codes.*,
    capacity
  from (
    select
      sms.sending_locations.id,
      profile_id,
      reference_name,
      center,
      sending_account_id,
      sms.sending_accounts.display_name as sending_account_name,
      unnest(area_codes) as area_code
    from sms.sending_locations
    join sms.profiles
      on sms.profiles.id = sms.sending_locations.profile_id
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.profiles.sending_account_id
  ) as sending_location_area_codes
  join sms.area_code_capacities
    on sms.area_code_capacities.area_code = sending_location_area_codes.area_code
    and sms.area_code_capacities.sending_account_id = sending_location_area_codes.sending_account_id;
