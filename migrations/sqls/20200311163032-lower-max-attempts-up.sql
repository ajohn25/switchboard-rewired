-- Make trigger job (currently only used for process-message) is 5
create or replace function trigger_job() returns trigger as $$
declare
  v_job json;
begin
  select row_to_json(NEW) into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job, null, 5);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

-- Make trigger job with profile info have 5
create or replace function trigger_job_with_profile_info() returns trigger as $$
declare
  v_job json;
  v_sending_location_id uuid;
  v_profile_json json;
begin
  select row_to_json(NEW) into v_job;

  if TG_TABLE_NAME = 'delivery_reports' then
    select sending_location_id
    from sms.outbound_messages
    where sms.outbound_messages.id = NEW.message_id
    into v_sending_location_id;
  else
    v_sending_location_id := NEW.sending_location_id;
  end if;

  select row_to_json(relevant_profile_fields)
  from (
    select
      profiles.id as profile_id,
      clients.access_token as encrypted_client_access_token,
      sms.sending_locations.id as sending_location_id,
      profiles.message_status_webhook_url,
      profiles.reply_webhook_url
    from sms.sending_locations
    join sms.profiles as profiles on profiles.id = sms.sending_locations.profile_id
    join billing.clients as clients on clients.id = profiles.client_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_profile_fields
  into v_profile_json;

  select v_job::jsonb || v_profile_json::jsonb into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job, null, 5);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

-- Make trigger job with sending account info have 5
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

-- Make trigger send message have max attempts 5
create or replace function sms.trigger_send_message() returns trigger as $$
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
  perform assemble_worker.add_job('send-message', v_job, NEW.send_after, 5);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;


