-- Add Twilio Service Profiles
-- --------------------------------------------

create table sms.twilio_profile_service_configurations (
  id uuid primary key default uuid_generate_v1mc(),
  messaging_service_sid text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table sms.twilio_profile_service_configurations is E'@omit';
comment on column sms.twilio_profile_service_configurations.created_at is E'@omit create,update,delete';
comment on column sms.twilio_profile_service_configurations.updated_at is E'@omit create,update,delete';

alter table sms.twilio_profile_service_configurations enable row level security;

create trigger _500_updated_at
  before update
  on sms.twilio_profile_service_configurations
  for each row
  execute function public.universal_updated_at();


-- Add Telnyx Service Profiles
-- --------------------------------------------

create table sms.telnyx_profile_service_configurations (
  id uuid primary key default uuid_generate_v1mc(),
  messaging_profile_id text,
  billing_group_id text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table sms.telnyx_profile_service_configurations is E'@omit';
comment on column sms.telnyx_profile_service_configurations.created_at is E'@omit create,update,delete';
comment on column sms.telnyx_profile_service_configurations.updated_at is E'@omit create,update,delete';

alter table sms.telnyx_profile_service_configurations enable row level security;

create trigger _500_updated_at
  before update
  on sms.telnyx_profile_service_configurations
  for each row
  execute function public.universal_updated_at();


-- Add Service Profiles
-- --------------------------------------------

create table sms.profile_service_configurations (
  id uuid primary key default uuid_generate_v1mc(),
  twilio_configuration_id uuid references sms.twilio_profile_service_configurations (id) on delete cascade,
  telnyx_configuration_id uuid references sms.telnyx_profile_service_configurations (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ensure_single_service_profile
    check (num_nonnulls(twilio_configuration_id, telnyx_configuration_id) <= 1)
);

comment on table sms.profile_service_configurations is E'@omit';
comment on column sms.profile_service_configurations.created_at is E'@omit create,update,delete';
comment on column sms.profile_service_configurations.updated_at is E'@omit create,update,delete';

alter table sms.profile_service_configurations enable row level security;

create trigger _500_updated_at
  before update
  on sms.profile_service_configurations
  for each row
  execute function public.universal_updated_at();

alter table sms.profiles
  add column profile_service_configuration_id uuid
    references sms.profile_service_configurations (id)
    on delete cascade;


-- Migrate Twilio Messaging Service SIDs
-- --------------------------------------------

with new_twilio_profile_service_configurations as (
  insert into sms.twilio_profile_service_configurations (messaging_service_sid)
  select profiles.service_profile_id
  from sms.profiles
  join sms.sending_accounts on profiles.sending_account_id = sending_accounts.id
  where
    sending_accounts.service = 'twilio'
  returning id
)
insert into sms.profile_service_configurations (twilio_configuration_id)
select id
from new_twilio_profile_service_configurations;

update sms.profiles
set profile_service_configuration_id = profile_service_configurations.id
from sms.profile_service_configurations, sms.twilio_profile_service_configurations
where
  profiles.service_profile_id = twilio_profile_service_configurations.messaging_service_sid
  and profile_service_configurations.twilio_configuration_id = twilio_profile_service_configurations.id;


-- Migrate Telnyx Profile IDs
-- --------------------------------------------

with new_telnyx_profile_service_configurations as (
  insert into sms.telnyx_profile_service_configurations (messaging_profile_id)
  select profiles.service_profile_id
  from sms.profiles
  join sms.sending_accounts on profiles.sending_account_id = sending_accounts.id
  where
    sending_accounts.service = 'telnyx'
  returning id
)
insert into sms.profile_service_configurations (telnyx_configuration_id)
select id from new_telnyx_profile_service_configurations;

update sms.profiles
set profile_service_configuration_id = profile_service_configurations.id
from sms.profile_service_configurations, sms.telnyx_profile_service_configurations
where
  profiles.service_profile_id = telnyx_profile_service_configurations.messaging_profile_id
  and profile_service_configurations.telnyx_configuration_id = telnyx_profile_service_configurations.id;


-- Drop deprecated Profiles column
-- --------------------------------------------

alter table sms.profiles
  drop column service_profile_id;


-- Update attach_10dlc_campaign_to_profile
-- --------------------------------------------

create or replace function attach_10dlc_campaign_to_profile(profile_id uuid, campaign_identifier text) returns boolean as $$
declare
  v_sending_account_json jsonb;
  v_overallocated_count bigint;
  v_overallocated_sending_location_id uuid;
begin
  update sms.profiles
  set service_10dlc_campaign_id = campaign_identifier,
    throughput_limit = 4500, -- from 75 per second
    daily_contact_limit = 3000000 -- 75 per second 
  where id = attach_10dlc_campaign_to_profile.profile_id;

  -- cordon all except 1 number per sending location
  update sms.all_phone_numbers
  set cordoned_at = now()
  where sms.all_phone_numbers.id <> (
      select id
      from sms.all_phone_numbers do_not_cordon
      where do_not_cordon.sending_location_id = sms.all_phone_numbers.sending_location_id
      order by phone_number asc
      limit 1
    )
    and sending_location_id in ( 
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = attach_10dlc_campaign_to_profile.profile_id
    );

  with jobs_added as (
    select 
      sending_location_id, 
      assemble_worker.add_job('associate-service-10dlc-campaign', row_to_json(job_payloads))
    from (
      select 
        sa.id as sending_account_id,
        sa.service as service,
        p.id as profile_id,
        p.service_10dlc_campaign_id,
        p.voice_callback_url,
        sa.twilio_credentials,
        sa.telnyx_credentials,
        pnr.sending_location_id,
        pnr.area_code,
        pnr.created_at,
        pnr.phone_number,
        pnr.commitment_count,
        pnr.service_order_id
      from sms.all_phone_numbers pn
      join sms.phone_number_requests pnr on pn.phone_number = pnr.phone_number
        and pnr.sending_location_id = pn.sending_location_id
      join sms.sending_locations sl on sl.id = pn.sending_location_id
      join sms.profiles p on sl.profile_id = p.id
      join sms.sending_accounts sa on p.sending_account_id = sa.id
      where pn.cordoned_at is null
        and p.id = attach_10dlc_campaign_to_profile.profile_id
    ) job_payloads
  )
  select count(*), sending_location_id
  from jobs_added
  group by 2
  having count(*) > 1
  into v_overallocated_count, v_overallocated_sending_location_id;

  -- if it's 0, that's ok, we'll associate the number when we buy it
  -- if it's more than 1, something went wrong with the above query
  if v_overallocated_count is not null and v_overallocated_sending_location_id is not null then
    raise 'error: too many numbers allocated to 10DLC campaign - % on %', 
      v_overallocated_count, v_overallocated_sending_location_id;
  end if;

  return true;
end;
$$ language plpgsql security definer;


-- Update sending_account_info function
-- --------------------------------------------

drop function sending_account_info(uuid);
create or replace function sending_account_info(sending_location_id uuid)
  returns table (
    sending_account_id uuid,
    service sms.profile_service_option,
    twilio_credentials sms.twilio_credentials,
    telnyx_credentials sms.telnyx_credentials
  )
as $$
begin
  return query
    select
      sending_accounts.id as sending_account_id,
      sending_accounts.service,
      sending_accounts.twilio_credentials,
      sending_accounts.telnyx_credentials
    from sms.sending_locations
    join sms.profiles profiles on sms.sending_locations.profile_id = profiles.id
    join sms.sending_accounts as sending_accounts
      on sending_accounts.id = profiles.sending_account_id
    where sms.sending_locations.id = sending_account_info.sending_location_id;
end;
$$ language plpgsql strict set search_path from current security definer;


-- Update trigger_job_with_sending_account_and_profile_info function
-- --------------------------------------------------------------------

create or replace function public.trigger_job_with_sending_account_and_profile_info() returns trigger as $$
declare
  v_job json;
  v_sending_location_id uuid;
  v_sending_account_json json;
begin
  select row_to_json(NEW) into v_job;

  if TG_TABLE_NAME = 'sending_locations' then
    v_sending_location_id := NEW.id;
  else
    v_sending_location_id := NEW.sending_location_id;
  end if;

  select row_to_json(relevant_sending_account_fields)
  from (
    select
      sending_account.id as sending_account_id,
      sending_account.service,
      sending_account.twilio_credentials,
      sending_account.telnyx_credentials,
      sms.profiles.id as profile_id,
      sms.profiles.voice_callback_url as voice_callback_url
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    join sms.sending_accounts_as_json as sending_account
      on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;
