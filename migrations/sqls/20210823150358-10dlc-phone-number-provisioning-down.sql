-- Job Flow: Twilio
drop trigger _500_twilio_complete_10dlc_purchase on sms.phone_number_requests;
drop trigger _500_twilio_associate_service_profile on sms.phone_number_requests;
drop trigger _500_twilio_complete_basic_purchase on sms.phone_number_requests;

-- Job Flow: Telnyx
drop trigger _500_telnyx_complete_10dlc_purchase on sms.phone_number_requests;
drop trigger _500_telnyx_associate_10dlc_campaign on sms.phone_number_requests;
drop trigger _500_telnyx_complete_basic_purchase on sms.phone_number_requests;
drop trigger _500_telnyx_associate_service_profile on sms.phone_number_requests;

drop trigger _500_poll_number_order_for_readiness on sms.phone_number_requests;
create trigger _500_poll_number_order_for_readiness
  after update on sms.phone_number_requests
  for each row when (OLD.service_order_id is null and NEW.service_order_id is not null)
  execute procedure trigger_job_with_sending_account_info('poll-number-order');

-- Revert sms.tg__phone_number_requests__fulfill
create or replace function sms.tg__phone_number_requests__fulfill() returns trigger
  language plpgsql
  as $$
begin
  insert into sms.phone_numbers (
    sending_location_id,
    phone_number,
    daily_contact_limit,
    throughput_interval,
    throughput_limit
  )
  values (
    NEW.sending_location_id,
    NEW.phone_number,
    NEW.daily_contact_limit,
    NEW.throughput_interval,
    NEW.throughput_limit
  );

  with interval_waits as (
    select
      id,
      to_number,
      original_created_at,
      sum(estimated_segments) over (partition by 1 order by original_created_at) as nth_segment
    from (
      select id, to_number, estimated_segments, original_created_at
      from sms.outbound_messages_routing
      where pending_number_request_id = NEW.id
        and sms.outbound_messages_routing.stage = 'awaiting-number'::sms.outbound_message_stages
        and sms.outbound_messages_routing.original_created_at > NEW.created_at - interval '1 day'
    ) all_messages
  )
  update sms.outbound_messages_routing
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages,
      send_after = now() + (interval_waits.nth_segment * NEW.throughput_interval / NEW.throughput_limit)
  from interval_waits
  where
    -- join on indexed to_number
    interval_waits.to_number = sms.outbound_messages_routing.to_number
    -- then filter by un-indexed sms.outbound_messages_routing.id
    and interval_waits.id = sms.outbound_messages_routing.id
    and interval_waits.original_created_at = sms.outbound_messages_routing.original_created_at;

  return NEW;
end;
$$;

-- Drop sms.tg__complete_number_purchase
drop function sms.tg__complete_number_purchase();

-- Revert trigger_job_with_sending_account_and_profile_info
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

-- Revert phone number request type
drop trigger _500_set_request_type on sms.phone_number_requests;
drop function sms.tg__set_phone_request_type();

-- Revert table changes
alter table sms.phone_number_requests
  drop column service,
  drop column service_10dlc_campaign_id,
  drop column service_order_completed_at,
  drop column service_profile_associated_at,
  drop column service_10dlc_campaign_associated_at;

alter table sms.profiles
  drop column service_10dlc_campaign_id;

drop view assemble_worker.all_jobs;
