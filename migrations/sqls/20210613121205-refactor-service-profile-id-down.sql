-- Revert trigger
create or replace function trigger_job_with_sending_account_info() returns trigger as $$
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
    select sending_account.id as sending_account_id, sending_account.service, sending_account.twilio_credentials, sending_account.telnyx_credentials
      from sms.sending_locations
      join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
      join sms.sending_accounts_as_json as sending_account
        on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job, null, 5);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

-- Drop util function
drop function sending_account_info(uuid);


-- Messaging Profile ID
-- ----------------------------

-- Restore telnyx_credentials type attribute
alter type sms.telnyx_credentials
  add attribute messaging_profile_id text;

-- Backfill messaging_profile_id from sms.profiles
update sms.sending_accounts sa
set telnyx_credentials.messaging_profile_id = p.service_profile_id
from sms.profiles p
where
  sa.id = p.sending_account_id
  and sa.service = 'telnyx';

-- Drop columns on sms.profiles
alter table sms.profiles
  drop column service_profile_id;
