-- Revert trigger_job_with_profile_info()
-- ----------------------------------------------

CREATE OR REPLACE FUNCTION public.trigger_job_with_profile_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
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
$$;


-- Revert sms.resolve_delivery_reports()
-- ----------------------------------------------

CREATE OR REPLACE FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$
  with update_result as (
    update sms.delivery_reports
    set message_id = sms.outbound_messages_telco.id
    from sms.outbound_messages_telco
    where sms.delivery_reports.message_service_id = sms.outbound_messages_telco.service_id
      and sms.delivery_reports.message_id is null
      and sms.delivery_reports.created_at >= now() - as_far_back_as
      and sms.delivery_reports.created_at <= now() - as_recent_as
    returning
      sms.delivery_reports.*
  ),
  payloads as (
    select
      update_result.message_service_id,
      update_result.message_id,
      update_result.event_type,
      update_result.generated_at,
      update_result.created_at,
      update_result.service,
      update_result.validated,
      update_result.error_codes,
      (
        coalesce(update_result.extra, '{}'::json)::jsonb || json_build_object(
          'num_segments', sms.outbound_messages_telco.num_segments,
          'num_media', sms.outbound_messages_telco.num_media
        )::jsonb
      )::json as extra
    from update_result
    join sms.outbound_messages_telco
      on update_result.message_id = sms.outbound_messages_telco.id
  ),
  job_insert_result as (
    insert into assemble_worker.jobs(
      queue_name,
      payload,
      max_attempts,
      run_at,
      status
    )
    select
      'forward-delivery-report',
      row_to_json(payloads)::jsonb || row_to_json(relevant_profile_fields)::jsonb,
      6,
      null,
      'running'
    from payloads
    join (
      select
        outbound_messages.id as message_id,
        profiles.id as profile_id,
        clients.access_token as encrypted_client_access_token,
        sms.sending_locations.id as sending_location_id,
        profiles.message_status_webhook_url,
        profiles.reply_webhook_url
      from sms.outbound_messages as outbound_messages
      join sms.sending_locations
        on sms.sending_locations.id = outbound_messages.sending_location_id
      join sms.profiles as profiles on profiles.id = sms.sending_locations.profile_id
      join billing.clients as clients on clients.id = profiles.client_id
    ) relevant_profile_fields
      on relevant_profile_fields.message_id = payloads.message_id
    returning 1
  )
  select count(*) from job_insert_result
$$;


-- Revert sms.tg__phone_number_requests__fulfill()
-- ----------------------------------------------

CREATE OR REPLACE FUNCTION sms.tg__phone_number_requests__fulfill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

  with interval_waits as (
    select
      id,
      sum(estimated_segments) over (partition by 1 order by created_at) as nth_segment
    from sms.outbound_messages
    where pending_number_request_id = NEW.id
      and sms.outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages
  )
  update sms.outbound_messages
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages,
      send_after = now() + (interval_waits.nth_segment * interval '10 seconds')
  from interval_waits
  where interval_waits.id = sms.outbound_messages.id;

  return NEW;
end;
$$;


-- Drop is_current_period management
-- ----------------------------------------------

drop function sms.update_is_current_period_indexes();

-- Revert choose_existing_available_number()
-- ----------------------------------------------

create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns public.phone_number
    language plpgsql
    as $$
declare
  v_phone_number phone_number;
begin
  -- First, check for numbers not texted today
  select phone_number
  from sms.phone_numbers
  where sending_location_id = ANY(sending_location_id_options)
    and cordoned_at is null
    and not exists (
      select 1
      from sms.fresh_phone_commitments
      where sms.fresh_phone_commitments.phone_number = sms.phone_numbers.phone_number
    )
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  -- Next, find the one least texted not currently overloaded and not cordoned
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and commitment <= 200
    and phone_number not in (
      select from_number
      from sms.outbound_messages
      where processed_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
      group by sms.outbound_messages.from_number
      having sum(estimated_segments) > 6
    )
    -- Check that this phone number isn't cordoned
    and not exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.phone_number = sms.fresh_phone_commitments.phone_number
        and not (cordoned_at is null)
    )
  order by commitment
  for update skip locked
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$;


-- Revert process_message()
-- ------------------------------------------------------------------

drop function sms.process_message(sms.outbound_messages);

CREATE OR REPLACE FUNCTION sms.process_message(message sms.outbound_messages) RETURNS sms.outbound_messages
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_sending_location_id uuid;
  v_prev_mapping_from_number phone_number;
  v_prev_mapping_created_at timestamp;
  v_prev_mapping_first_send_of_day boolean;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number, created_at
  from sms.outbound_messages
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages.from_number
        and (
          sms.phone_numbers.cordoned_at is null
          or
          sms.phone_numbers.cordoned_at > now() - interval '3 days'
        )
    )
  order by created_at desc
  limit 1
  into v_prev_mapping_from_number, v_prev_mapping_created_at;

  if v_prev_mapping_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where phone_number = v_prev_mapping_from_number
    into v_sending_location_id;

    select
      v_prev_mapping_created_at <
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    into v_prev_mapping_first_send_of_day;

    update sms.outbound_messages
    set from_number = v_prev_mapping_from_number,
        stage = 'queued',
        sending_location_id = v_sending_location_id,
        decision_stage = 'prev_mapping',
        processed_at = now(),
        first_from_to_pair_of_day = v_prev_mapping_first_send_of_day
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select sms.choose_existing_available_number(ARRAY[v_sending_location_id])
  into v_from_number;

  if v_from_number is not null then
    update sms.outbound_messages
    set from_number = v_from_number,
        stage = 'queued',
        decision_stage = 'existing_phone_number',
        processed_at = now(),
        sending_location_id = v_sending_location_id
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it means we need to buy a new number
  -- this could be because no numbers exist, or all are at or above capacity

  -- try to map it to existing pending number request
  select pending_number_request_id
  from sms.pending_number_request_capacity
  where commitment_count < 200
    and sms.pending_Number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    update sms.outbound_messages
    set pending_number_request_id = v_pending_number_request_id,
        stage = 'awaiting-number',
        sending_location_id = v_sending_location_id,
        decision_stage = 'existing_pending_request',
        processed_at = now()
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;

  -- need to create phone_number_request - gotta pick an area code
  select sms.choose_area_code_for_sending_location(v_sending_location_id) into v_area_code;

  insert into sms.phone_number_requests (sending_location_id, area_code)
  values (v_sending_location_id, v_area_code)
  returning id
  into v_pending_number_request_id;

  update sms.outbound_messages
  set pending_number_request_id = v_pending_number_request_id,
      stage = 'awaiting-number',
      sending_location_id = v_sending_location_id,
      decision_stage = 'new_pending_request',
      processed_at = now()
  where id = message.id
  returning *
  into v_result;

  return v_result;
end;
$$;


-- Revert trigger_send_message()
-- ------------------------------------------------------------------

CREATE OR REPLACE FUNCTION sms.trigger_send_message() RETURNS trigger
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
    select sending_account.id as sending_account_id, sending_account.service, sending_account.twilio_credentials, sending_account.telnyx_credentials
      from sms.sending_locations
      join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
      join sms.sending_accounts_as_json as sending_account
        on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;

  if (cardinality(NEW.media_urls) is null or cardinality(NEW.media_urls) = 0) then
    perform assemble_worker.add_job('send-message', v_job, NEW.send_after, 5);
  else
    perform graphile_worker.add_job(
      'send-message',
      v_job,
      run_at => NEW.send_after,
      max_attempts => 5,
      flags => ARRAY['send-message-mms:global']
    );
  end if;

  return NEW;
end;
$$;


--- Drop sms.outbound_messages_teclo
--- ---------------------------------------------

drop table sms.outbound_messages_routing;

create trigger _500_increment_commitment_bucket_after_insert
  after insert on sms.outbound_messages
  for each row
  when (new.from_number is not null and new.first_from_to_pair_of_day = true)
  execute procedure sms.increment_commitment_bucket_if_unique();

create trigger _500_increment_commitment_bucket_after_update
  after update on sms.outbound_messages
  for each row
  when (old.from_number is null and new.from_number is not null and new.first_from_to_pair_of_day = true)
  execute procedure sms.increment_commitment_bucket_if_unique();

create trigger _500_increment_pending_request_commitment_after_insert
  after insert on sms.outbound_messages
  for each row
  when (new.pending_number_request_id is not null)
  execute procedure sms.tg__outbound_messages__increment_pending_request_commitment();

create trigger _500_increment_pending_request_commitment_after_update
  after update on sms.outbound_messages
  for each row
  when (new.pending_number_request_id is not null and old.pending_number_request_id is null)
  execute procedure sms.tg__outbound_messages__increment_pending_request_commitment();

create trigger _500_send_message_after_fulfillment
  after update on sms.outbound_messages
  for each row
  when (old.stage = 'awaiting-number'::sms.outbound_message_stages and new.stage = 'queued'::sms.outbound_message_stages)
  execute procedure sms.trigger_send_message();

create trigger _500_send_message_after_process
  after update on sms.outbound_messages
  for each row
  when (new.stage = 'queued'::sms.outbound_message_stages and old.stage = 'processing'::sms.outbound_message_stages)
  execute procedure sms.trigger_send_message();

create trigger _500_send_message_basic
  after insert on sms.outbound_messages
  for each row
  when (new.stage = 'queued'::sms.outbound_message_stages)
  execute procedure sms.trigger_send_message();

-- No need to recreate _500_process_outbound_message -- it was never migrated to routing table


-- Revert indexes
-- ----------------------------------------------

drop index sms.outbound_messages_phone_number_overloaded_idx;
create index outbound_messages_phone_number_overloaded_idx
  on sms.outbound_messages (processed_at desc, from_number)
  include (estimated_segments)
  where
    stage <> 'awaiting-number'::sms.outbound_message_stages;


-- Drop is_current_period column
-- ----------------------------------------------

alter table sms.outbound_messages
  drop column is_current_period;
