-- Test Helpers
-- ----------------------------

create view assemble_worker.all_jobs as
  select queue_name, payload, created_at from assemble_worker.jobs
  union all
  select queue_name, payload, created_at from assemble_worker.pending_jobs;

-- Phone Number Purchasing Flow
-- ----------------------------

-- Add optional 10DLC campaign association column to sms.profiles
alter table sms.profiles
  add column service_10dlc_campaign_id text;

-- Changes to number purchasing flow
alter table sms.phone_number_requests
  -- Denormalize fields required for triggers
  add column service sms.profile_service_option,
  add column service_10dlc_campaign_id text,
  -- Track completion of Telnyx number order (previously this just completed the phone number purchase)
  add column service_order_completed_at timestamptz,
  -- Track association with Telnyx Messaging Profile / Twilio Messaging Service
  add column service_profile_associated_at timestamptz,
  -- Track when Telnyx number was associated with 10DLC campaign
  add column service_10dlc_campaign_associated_at timestamptz;


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

create trigger _500_set_request_type
  before insert
  on sms.phone_number_requests
  for each row
  execute procedure sms.tg__set_phone_request_type();

-- Job Flow: Common Completion
-- ----------------------------

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
      sms.profiles.voice_callback_url as voice_callback_url,
      sms.profiles.service_profile_id as service_profile_id
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

create or replace function sms.tg__complete_number_purchase() returns trigger
  language plpgsql strict security definer
  as $$
begin
  NEW.fulfilled_at := CURRENT_TIMESTAMP;
  return NEW;
end;
$$;

create or replace function sms.tg__phone_number_requests__fulfill() returns trigger
  language plpgsql
  as $$
declare
  v_sending_account_id uuid;
  v_capacity integer;
  v_purchasing_strategy sms.number_purchasing_strategy;
begin
  -- Create the phone number record
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

  select sending_account_id
  from sms.profiles profiles
  join sms.sending_locations locations on locations.profile_id = profiles.id
  where locations.id = NEW.sending_location_id
  into v_sending_account_id;

  -- Update area code capacities
  with update_result as (
    update sms.area_code_capacities
    set capacity = capacity - 1
    where
      area_code = NEW.area_code
      and sending_account_id = v_sending_account_id
    returning capacity
  )
  select capacity
  from update_result
  into v_capacity;

  if ((v_capacity is not null) and (mod(v_capacity, 5) = 0)) then
    select purchasing_strategy
    from sms.sending_locations
    where id = NEW.sending_location_id
    into v_purchasing_strategy;

    if v_purchasing_strategy = 'exact-area-codes' then
      perform sms.refresh_one_area_code_capacity(NEW.area_code, v_sending_account_id);
    elsif v_purchasing_strategy = 'same-state-by-distance' then
      perform sms.queue_find_suitable_area_codes_refresh(NEW.sending_location_id);
    else
      raise exception 'Unknown purchasing strategy: %', v_purchasing_strategy;
    end if;
  end if;

  -- Process queued outbound messages
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

-- Job Flow: Telnyx
-- ----------------------------

-- Restrict poll-number-order to telnyx
drop trigger _500_poll_number_order_for_readiness on sms.phone_number_requests;
create trigger _500_poll_number_order_for_readiness
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.phone_number is not null)
    and ((OLD.service_order_id is null) and (NEW.service_order_id is not null))
  )
  execute procedure trigger_job_with_sending_account_info('poll-number-order');

-- Always associate Telnyx messaging profiles
create trigger _500_telnyx_associate_service_profile
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.phone_number is not null)
    and ((old.service_order_completed_at is null) and (new.service_order_completed_at is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-profile');

-- Complete purchase after messaging profile association IFF it IS NOT a 10DLC campaign
create trigger _500_telnyx_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is null)
    and ((old.service_profile_associated_at is null) and (new.service_profile_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

-- Associate 10DLC campaign after messaging profile association IFF it IS a 10DLC campaign
create trigger _500_telnyx_associate_10dlc_campaign
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is not null)
    and ((old.service_profile_associated_at is null) and (new.service_profile_associated_at is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

-- Complete purchase after 10DLC association IFF it IS a 10DLC campaign
create trigger _500_telnyx_complete_10dlc_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.service_10dlc_campaign_id is not null)
    and ((old.service_10dlc_campaign_associated_at is null) and (new.service_10dlc_campaign_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();


-- Job Flow: Twilio
-- ----------------------------

-- Complete purchase request IFF it IS NOT a 10DLC campaign
create trigger _500_twilio_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is null)
    and ((old.phone_number is null) and (new.phone_number is not null))
  )
  execute procedure sms.tg__complete_number_purchase();

-- Associate Twilio Messaging Service IFF it IS a 10DLC campaign
create trigger _500_twilio_associate_service_profile
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is not null)
    and ((old.phone_number is null) and (new.phone_number is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');

-- Complete purchase request IFF it IS a 10DLC campaign AND the messaging service has been associated
create trigger _500_twilio_complete_10dlc_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'twilio' and new.service_10dlc_campaign_id is not null)
    and ((old.service_10dlc_campaign_associated_at is null) and (new.service_10dlc_campaign_associated_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();
