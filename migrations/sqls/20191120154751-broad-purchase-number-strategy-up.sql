create type sms.number_purchasing_strategy as enum (
  'exact-area-codes',
  'same-state-by-distance'
);

alter table sms.profiles
  add column default_purchasing_strategy sms.number_purchasing_strategy
  default 'same-state-by-distance'::sms.number_purchasing_strategy not null;

alter table sms.sending_locations
  add column purchasing_strategy sms.number_purchasing_strategy not null;

create or replace function sms.tg__sending_locations__strategy_inherit() returns trigger as $$
declare
  v_profile_purchasing_strategy sms.number_purchasing_strategy;
begin
  select default_purchasing_strategy
  from sms.profiles
  where id = NEW.profile_id
  into v_profile_purchasing_strategy;

  NEW.purchasing_strategy := v_profile_purchasing_strategy;
  return NEW;
end;
$$ language plpgsql;

create trigger _500_inherit_purchasing_strategy
  before insert
  on sms.sending_locations
  for each row
  when (NEW.purchasing_strategy is null)
  execute procedure sms.tg__sending_locations__strategy_inherit();

create trigger _500_find_suitable_area_codes
  after insert
  on sms.sending_locations
  for each row
  when (NEW.purchasing_strategy = 'same-state-by-distance'::sms.number_purchasing_strategy)
  execute procedure trigger_job_with_sending_account_info('find-suitable-area-codes');

create or replace function sms.queue_find_suitable_area_codes_refresh(sending_location_id uuid) returns void as $$
begin
  perform assemble_worker.add_job('find-suitable-area-codes', row_to_json(all_area_code_capacity_job_info))
  from (
    select
      sms.sending_locations.*,
      sms.sending_accounts.id as sending_account_id,
      sms.sending_accounts.service,
      sms.sending_accounts.twilio_credentials,
      sms.sending_accounts.telnyx_credentials
    from sms.sending_locations
    join sms.profiles
      on sms.sending_locations.profile_id = sms.profiles.id
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = sending_location_id
    limit 1
  ) as all_area_code_capacity_job_info;
end;
$$ language plpgsql;

create or replace function sms.compute_sending_location_capacity(sending_location_id uuid) returns integer as $$
  with sending_location_info as (
    select sms.profiles.sending_account_id, sms.sending_locations.area_codes
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.sending_locations.id = compute_sending_location_capacity.sending_location_id
    limit 1
  )
  select sum(capacity)::integer
  from sms.area_code_capacities
  where sms.area_code_capacities.sending_account_id = (
      select sending_account_id
      from sending_location_info
    )
    and area_code in ( 
      select unnest(area_codes)
      from sending_location_info
    )
$$ language sql;

drop trigger _500_queue_determine_area_code_capacity_after_update on sms.sending_locations;
create trigger _500_queue_determine_area_code_capacity_after_update
  after update
  on sms.sending_locations
  for each row
  when (OLD.area_codes <> NEW.area_codes and array_length(NEW.area_codes, 1) > 0 and NEW.purchasing_strategy = 'exact-area-codes'::sms.number_purchasing_strategy)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');

drop trigger _500_queue_determine_area_code_capacity_after_insert on sms.sending_locations;
create trigger _500_queue_determine_area_code_capacity_after_insert
  after insert
  on sms.sending_locations
  for each row
  when (NEW.area_codes is not null and array_length(NEW.area_codes, 1) > 0 and NEW.purchasing_strategy = 'exact-area-codes'::sms.number_purchasing_strategy)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');
