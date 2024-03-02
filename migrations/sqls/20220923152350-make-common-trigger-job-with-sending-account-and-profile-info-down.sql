/* Replace with your SQL commands */
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
$$;

DROP FUNCTION public.add_job_with_sending_account_and_profile_info;

create trigger _500_bandwidth_associate_10dlc_campaign 
  AFTER UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL)
  EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_bandwidth_complete_10dlc_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();

create trigger _500_bandwidth_complete_basic_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.tendlc_campaign_id IS NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();

create trigger _500_poll_number_order_for_readiness 
  AFTER UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN ((new.service = 'telnyx'::sms.profile_service_option OR new.service = 'bandwidth'::sms.profile_service_option) AND new.phone_number IS NOT NULL AND old.service_order_id IS NULL AND new.service_order_id IS NOT NULL)
  EXECUTE FUNCTION trigger_job_with_sending_account_info('poll-number-order');

create trigger _500_telnyx_associate_10dlc_campaign 
  AFTER UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.service_profile_associated_at IS NULL AND new.service_profile_associated_at IS NOT NULL)
  EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_telnyx_associate_service_profile 
  AFTER UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.phone_number IS NOT NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL)
  EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-profile');

create trigger _500_telnyx_complete_10dlc_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();

create trigger _500_telnyx_complete_basic_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.tendlc_campaign_id IS NULL AND old.service_profile_associated_at IS NULL AND new.service_profile_associated_at IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();

create trigger _500_twilio_associate_service_profile 
  AFTER UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.phone_number IS NULL AND new.phone_number IS NOT NULL)
  EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

create trigger _500_twilio_complete_10dlc_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.tendlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();

create trigger _500_twilio_complete_basic_purchase 
  BEFORE UPDATE 
  ON sms.phone_number_requests 
  FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.tendlc_campaign_id IS NULL AND old.phone_number IS NULL AND new.phone_number IS NOT NULL)
  EXECUTE FUNCTION sms.tg__complete_number_purchase();
