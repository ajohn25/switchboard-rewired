CREATE OR REPLACE FUNCTION public.add_job_with_sending_account_and_profile_info(
	job_name text, core_payload json, param_sending_location_id uuid default null
) RETURNS void
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
	v_job json;
  v_sending_location_id uuid;
  v_sending_account_json json;
begin
  select coalesce(param_sending_location_id, (core_payload->>'sending_location_id')::uuid)
  into v_sending_location_id;

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

  select core_payload::jsonb || v_sending_account_json::jsonb into v_job;

  perform assemble_worker.add_job(job_name, v_job);
end;
$$;

CREATE OR REPLACE FUNCTION public.trigger_job_with_sending_account_and_profile_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
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

	perform add_job_with_sending_account_and_profile_info(TG_ARGV[0], v_job, v_sending_location_id);
  return NEW;
end;
$$;

drop trigger _500_bandwidth_associate_10dlc_campaign ON sms.phone_number_requests;
drop trigger _500_bandwidth_complete_10dlc_purchase ON sms.phone_number_requests;
drop trigger _500_bandwidth_complete_basic_purchase ON sms.phone_number_requests;
drop trigger _500_poll_number_order_for_readiness ON sms.phone_number_requests;
drop trigger _500_telnyx_associate_10dlc_campaign ON sms.phone_number_requests;
drop trigger _500_telnyx_associate_service_profile ON sms.phone_number_requests;
drop trigger _500_telnyx_complete_10dlc_purchase ON sms.phone_number_requests;
drop trigger _500_telnyx_complete_basic_purchase ON sms.phone_number_requests;
drop trigger _500_twilio_associate_service_profile ON sms.phone_number_requests;
drop trigger _500_twilio_complete_10dlc_purchase ON sms.phone_number_requests;
drop trigger _500_twilio_complete_basic_purchase ON sms.phone_number_requests;
