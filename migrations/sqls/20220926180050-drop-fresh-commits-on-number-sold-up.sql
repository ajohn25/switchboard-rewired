-- Fix trigger fns
-- ----------------------------

CREATE OR REPLACE FUNCTION public.trigger_sell_number() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
  v_sending_account_json json;
begin
  -- This check prevents this trigger from running as the result of 
  -- decomissioning a sending location
  -- Instead, this trigger is only for directly releasing specific phone number(s)
  if pg_trigger_depth() > 1 then
    return NEW;
  end if;

  select row_to_json(NEW) into v_job;

  select row_to_json(relevant_sending_account_fields)
  from (
    select sending_account.id as sending_account_id, sending_account.service, sending_account.twilio_credentials, sending_account.telnyx_credentials
      from sms.sending_locations
      join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
      join sms.sending_accounts_as_json as sending_account
        on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = NEW.sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  delete from sms.fresh_phone_commitments
  where
    phone_number = NEW.phone_number
    and sending_location_id = NEW.sending_location_id;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform graphile_worker.add_job('sell-number', v_job, max_attempts => 5);
  return NEW;
end;
$$;

CREATE OR REPLACE FUNCTION sms.cascade_sending_location_decomission() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_sending_account_json json;
begin
  select row_to_json(relevant_sending_account_fields)
  from (
    select sending_account.id as sending_account_id, sending_account.service, sending_account.twilio_credentials, sending_account.telnyx_credentials
      from sms.sending_locations
      join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
      join sms.sending_accounts_as_json as sending_account
        on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = NEW.id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  perform graphile_worker.add_job(
    'sell-number', 
    payload := (job::jsonb || v_sending_account_json::jsonb)::json, 
    max_attempts := 5, 
    run_at := now() + n * '1 second'::interval
  )
  from (
    select row_to_json(pn) as job, row_number() over (partition by 1) as n
    from sms.all_phone_numbers pn
    where pn.sending_location_id = NEW.id
      and released_at is null
  ) numbers;

  update sms.all_phone_numbers
  set released_at = NEW.decomissioned_at
  where sms.all_phone_numbers.sending_location_id = NEW.id
    and released_at is null;

  delete from sms.fresh_phone_commitments
  where sending_location_id = NEW.id;

  return NEW;
end;
$$;
