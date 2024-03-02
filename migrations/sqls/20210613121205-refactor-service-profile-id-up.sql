-- Messaging Profile ID
-- ----------------------------

-- Add columns to sms.profiles
alter table sms.profiles
  add column service_profile_id text;

-- Backfill values for Telnyx
update sms.profiles p
set service_profile_id = (sa.telnyx_credentials).messaging_profile_id
from sms.sending_accounts sa
where
  sa.id = p.sending_account_id
  and sa.service = 'telnyx';

-- Drop telnyx_credentials attribute
alter type sms.telnyx_credentials
  drop attribute messaging_profile_id;

-- Add util method for sending account information
create or replace function sending_account_info(sending_location_id uuid)
  returns table (
    sending_account_id uuid,
    service sms.profile_service_option,
    service_profile_id text,
    twilio_credentials sms.twilio_credentials,
    telnyx_credentials sms.telnyx_credentials
  )
as $$
begin
  return query
    select
      sending_accounts.id as sending_account_id,
      sending_accounts.service,
      profiles.service_profile_id,
      sending_accounts.twilio_credentials,
      sending_accounts.telnyx_credentials
    from sms.sending_locations
    join sms.profiles profiles on sms.sending_locations.profile_id = profiles.id
    join sms.sending_accounts as sending_accounts
      on sending_accounts.id = profiles.sending_account_id
    where sms.sending_locations.id = sending_account_info.sending_location_id;
end;
$$ language plpgsql strict set search_path from current security definer;

-- Update trigger
create or replace function trigger_job_with_sending_account_info() returns trigger as $$
declare
  v_job json;
  v_sending_account_json json;
begin
  select row_to_json(NEW) into v_job;

  if TG_TABLE_NAME = 'sending_locations' then
    v_sending_account_json := to_json(sending_account_info(NEW.id));
  else
    v_sending_account_json := to_json(sending_account_info(NEW.sending_location_id));
  end if;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job, null, 5);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;
