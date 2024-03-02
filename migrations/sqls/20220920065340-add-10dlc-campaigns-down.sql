-- Revert migrate campaigns
-- --------------------------------------------

-- Profiles

alter table sms.profiles
  add column service_10dlc_campaign_id text;

update sms.profiles
set service_10dlc_campaign_id = tc.registrar_campaign_id
from sms.tendlc_campaigns tc
where tc.id = tendlc_campaign_id;

alter table sms.profiles
  drop column tendlc_campaign_id;

-- Phone number requests -- drop triggers

drop trigger _500_bandwidth_associate_10dlc_campaign on sms.phone_number_requests;
drop trigger _500_bandwidth_complete_10dlc_purchase on sms.phone_number_requests;
drop trigger _500_bandwidth_complete_basic_purchase on sms.phone_number_requests;
drop trigger _500_telnyx_associate_10dlc_campaign on sms.phone_number_requests;
drop trigger _500_telnyx_complete_10dlc_purchase on sms.phone_number_requests;
drop trigger _500_telnyx_complete_basic_purchase on sms.phone_number_requests;
drop trigger _500_twilio_associate_service_profile on sms.phone_number_requests;
drop trigger _500_twilio_complete_10dlc_purchase on sms.phone_number_requests;
drop trigger _500_twilio_complete_basic_purchase on sms.phone_number_requests;

-- Phone number requests -- column changes and data migration

alter table sms.phone_number_requests
  add column service_10dlc_campaign_id text;

update sms.phone_number_requests
set service_10dlc_campaign_id = tendlc_campaigns.registrar_campaign_id
from sms.tendlc_campaigns
where
  phone_number_requests.tendlc_campaign_id = tendlc_campaigns.id;

alter table sms.phone_number_requests
  drop column tendlc_campaign_id;

-- Revert trigger functions

create or replace function sms.tg__set_phone_request_type() returns trigger
  language plpgsql strict security definer
  as $$
declare
  v_service sms.profile_service_option;
  v_10dlc_campaign_id text;
begin
  select
    sending_accounts.service,
    profiles.service_10dlc_campaign_id
  from sms.sending_accounts sending_accounts
  join sms.profiles profiles on profiles.sending_account_id = sending_accounts.id
  join sms.sending_locations sending_locations on sending_locations.profile_id = profiles.id
  where sending_locations.id = NEW.sending_location_id
  into v_service, v_10dlc_campaign_id;

  NEW.service := v_service;
  NEW.service_10dlc_campaign_id := v_10dlc_campaign_id;

  return NEW;
end;
$$;

-- Revert triggers

create trigger _500_bandwidth_associate_10dlc_campaign
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'bandwidth' and new.service_10dlc_campaign_id is not null)
    and ((old.service_order_completed_at is null) and (new.service_order_completed_at is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_bandwidth_complete_10dlc_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'bandwidth' and new.service_10dlc_campaign_id is not null)
    and ((old.service_10dlc_campaign_associated_at is null) and (new.service_10dlc_campaign_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

create trigger _500_bandwidth_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (NEW.service = 'bandwidth' and NEW.service_10dlc_campaign_id is null)
    and ((OLD.service_order_completed_at is null) and (NEW.service_order_completed_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

create trigger _500_telnyx_associate_10dlc_campaign
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is not null)
    and ((old.service_profile_associated_at is null) and (new.service_profile_associated_at is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_telnyx_complete_10dlc_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is not null)
    and ((old.service_10dlc_campaign_associated_at is null) and (new.service_10dlc_campaign_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

create trigger _500_telnyx_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is null)
    and ((old.service_profile_associated_at is null) and (new.service_profile_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

create trigger _500_twilio_associate_service_profile
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is not null)
    and ((old.phone_number is null) and (new.phone_number is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_twilio_complete_10dlc_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is not null)
    and ((old.service_10dlc_campaign_associated_at is null) and (new.service_10dlc_campaign_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

create trigger _500_twilio_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is null)
    and ((old.phone_number is null) and (new.phone_number is not null))
  )
  execute procedure sms.tg__complete_number_purchase();


-- Revert 10DLC campaign changes
-- --------------------------------------------

drop table sms.tendlc_campaigns;


-- Revert utility function
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
