create extension if not exists timescaledb;

alter table sms.delivery_reports drop constraint delivery_reports_message_id_fkey;
alter table sms.outbound_messages_telco drop constraint outbound_messages_telco_id_fkey;

alter table sms.outbound_messages drop constraint outbound_messages_pkey;

-- Without a slightly truncated timestamp, timestamp equality checks don't survive transitions
-- between PostgreSQL and Javascript. Some precision is lost, e.g.:
-- 2021-03-01 13:59:28.513115 (Postgresql) vs 2021-03-01 13:59:28.513 (Postgresql from JS)
alter table sms.outbound_messages alter column created_at set default date_trunc('second', now());

select create_hypertable(
  'sms.outbound_messages',
  'created_at',
  chunk_time_interval => interval '1 day',
  migrate_data => true
);

alter table sms.outbound_messages add primary key (created_at, id);

alter table sms.outbound_messages_routing add column original_created_at timestamp;
alter table sms.outbound_messages_telco add column original_created_at timestamp;

-- Dropping - it's redundant with `processed_at` and it's confusing with original_created_at
alter table sms.outbound_messages_routing drop column created_at;
alter table sms.outbound_messages_routing alter column processed_at set default now();

alter table sms.outbound_messages_telco add column sent_at timestamp default now();

alter table sms.outbound_messages_telco drop constraint outbound_messages_telco_pkey;

select create_hypertable(
  'sms.outbound_messages_routing',
  'original_created_at',
  chunk_time_interval => interval '1 day',
  migrate_data => true
);

select create_hypertable(
  'sms.outbound_messages_telco',
  'original_created_at',
  chunk_time_interval => interval '1 day',
  migrate_data => true
);

alter table sms.outbound_messages_routing add primary key (original_created_at, id);
alter table sms.outbound_messages_telco add primary key (original_created_at, id);

alter table sms.inbound_message_forward_attempts 
  drop constraint inbound_message_forward_attempts_message_id_fkey;

alter table sms.inbound_messages 
  drop constraint inbound_messages_pkey;

select create_hypertable(
  'sms.inbound_messages',
  'received_at',
  chunk_time_interval => interval '1 week',
  migrate_data => true
);

alter table sms.inbound_messages add primary key (received_at, id);

select create_hypertable(
  'sms.inbound_message_forward_attempts',
  'sent_at',
  chunk_time_interval => interval '1 week',
  migrate_data => true
);

select create_hypertable(
  'sms.delivery_reports',
  'created_at',
  chunk_time_interval => interval '1 week',
  migrate_data => true
);

drop index sms.delivery_reports_created_at_idx;

create index delivery_reports_created_at_idx
  on sms.delivery_reports using btree (created_at DESC, event_type);

drop index sms.delivery_reports_created_at_idx1;

select create_hypertable(
  'sms.delivery_report_forward_attempts',
  'sent_at',
  chunk_time_interval => interval '1 week',
  migrate_data => true
);


-- Code changes
DROP FUNCTION sms.process_message;
CREATE FUNCTION sms.process_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT NULL::interval) RETURNS sms.outbound_messages_routing
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_contact_zip_code public.zip_code;
  v_sending_location_id uuid;
  v_prev_mapping_from_number phone_number;
  v_prev_mapping_created_at timestamp;
  v_prev_mapping_first_send_of_day boolean;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages_routing;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  -- Note - right now, if prev_mapping_validity_interval is null, this searches over all time chunks
  -- we need to benchmark this in production to see what the chunk search penalty is
  select from_number, processed_at, sending_location_id
  from sms.outbound_messages_routing
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages_routing.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages_routing.from_number
        and (
          sms.phone_numbers.cordoned_at is null
          or
          sms.phone_numbers.cordoned_at > now() - interval '3 days'
        )
    )
    and (prev_mapping_validity_interval is null or processed_at > now() - prev_mapping_validity_interval)
  order by processed_at desc
  limit 1
  into v_prev_mapping_from_number, v_prev_mapping_created_at, v_sending_location_id;

  if v_prev_mapping_from_number is not null then
    select
      v_prev_mapping_created_at <
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    into v_prev_mapping_first_send_of_day;

    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      from_number,
      to_number,
      stage,
      sending_location_id,
      decision_stage,
      processed_at,
      first_from_to_pair_of_day
    )
    values (
      message.id,
      message.created_at,
      v_prev_mapping_from_number,
      message.to_number,
      'queued',
      v_sending_location_id,
      'prev_mapping',
      now(),
      v_prev_mapping_first_send_of_day
    )
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
    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      from_number,
      to_number,
      stage,
      decision_stage,
      processed_at,
      sending_location_id
    )
    values (
      message.id,
      message.created_at,
      v_from_number,
      message.to_number,
      'queued',
      'existing_phone_number',
      now(),
      v_sending_location_id
    )
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
    and sms.pending_number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    insert into sms.outbound_messages_routing (
      id,
      original_created_at,
      to_number,
      pending_number_request_id,
      stage,
      sending_location_id,
      decision_stage,
      processed_at
    )
    values (
      message.id,
      message.created_at,
      message.to_number,
      v_pending_number_request_id,
      'awaiting-number',
      v_sending_location_id,
      'existing_pending_request',
      now()
    )
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

  insert into sms.outbound_messages_routing (
    id,
    original_created_at,
    to_number,
    pending_number_request_id,
    stage,
    sending_location_id,
    decision_stage,
    processed_at
  )
  values (
    message.id,
    message.created_at,
    message.to_number,
    v_pending_number_request_id,
    'awaiting-number',
    v_sending_location_id,
    'new_pending_request',
    now()
  )
  returning *
  into v_result;

  return v_result;
end;
$$;

-- Needs to order by original_created_at and include original_created_at in update where clause
-- Limit the search to 1 day before the creation date of the phone request for time paritioning
CREATE OR REPLACE FUNCTION sms.tg__phone_number_requests__fulfill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

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
      send_after = now() + (interval_waits.nth_segment * interval '10 seconds')
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

CREATE OR REPLACE FUNCTION sms.trigger_send_message() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_message_body record;
  v_job json;
  v_sending_location_id uuid;
  v_sending_account_json json;
begin
  select body, media_urls, send_before
  from sms.outbound_messages
  where id = NEW.id
    and created_at = NEW.original_created_at
  into v_message_body;

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
      sending_account.telnyx_credentials
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    join sms.sending_accounts_as_json as sending_account
      on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  select row_to_json(v_message_body)::jsonb || v_job::jsonb || v_sending_account_json::jsonb into v_job;

  if (cardinality(v_message_body.media_urls) is null or cardinality(v_message_body.media_urls) = 0) then
    perform assemble_worker.add_job(
      'send-message',
      v_job,
      NEW.send_after, 5
    );
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

-- Only resolve messages sent within 1 day of the delivery report by default
DROP FUNCTION sms.resolve_delivery_reports;
CREATE OR REPLACE FUNCTION sms.resolve_delivery_reports(
  as_far_back_as interval, 
  as_recent_as interval, 
  fire_date timestamp without time zone DEFAULT now(),
  send_delay_window interval default '1 day'::interval 
) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$ 
with update_result as (
  update sms.delivery_reports
  set message_id = sms.outbound_messages_telco.id
  from sms.outbound_messages_telco
  where sms.delivery_reports.message_service_id = sms.outbound_messages_telco.service_id
    and sms.delivery_reports.message_id is null
    and sms.delivery_reports.created_at >= fire_date - as_far_back_as
    and sms.delivery_reports.created_at <= fire_date - as_recent_as
    and sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
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
    sms.outbound_messages_telco.original_created_at,
    (
      coalesce(update_result.extra, '{}'::json)::jsonb || json_build_object(
        'num_segments', sms.outbound_messages_telco.num_segments,
        'num_media', sms.outbound_messages_telco.num_media
      )::jsonb
    )::json as extra
  from update_result
  join sms.outbound_messages_telco
    on update_result.message_id = sms.outbound_messages_telco.id
  where sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
),
job_insert_result as (
  select graphile_worker.add_job(
    identifier => 'forward-delivery-report',
    payload => (row_to_json(payloads)::jsonb || row_to_json(relevant_profile_fields)::jsonb)::json,
    priority => 100,
    max_attempts => 6
  )
  from payloads
  join (
    select
      outbound_messages.id as message_id,
      outbound_messages.original_created_at as original_created_at,
      profiles.id as profile_id,
      clients.access_token as encrypted_client_access_token,
      sms.sending_locations.id as sending_location_id,
      profiles.message_status_webhook_url,
      profiles.reply_webhook_url
    from sms.outbound_messages_routing as outbound_messages
    join sms.sending_locations
      on sms.sending_locations.id = outbound_messages.sending_location_id
    join sms.profiles as profiles on profiles.id = sms.sending_locations.profile_id
    join billing.clients as clients on clients.id = profiles.client_id
  ) relevant_profile_fields
    on relevant_profile_fields.message_id = payloads.message_id
    and relevant_profile_fields.original_created_at = payloads.original_created_at
)
select count(*) from job_insert_result
$$;

-- This function isn't called - it should be dropped to ensure we don't
-- renable it without redefining it to also include a `original_created_at` filter
DROP FUNCTION sms.tg__delivery_reports__find_message_id;

-- This is the trigger that fires with an internally generated "fake" delivery report
-- I think we can safely limit its firing to 1 day since the original message was created
CREATE OR REPLACE FUNCTION public.trigger_forward_delivery_report_with_profile_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
  v_profile_id uuid;
  v_profile_json json;
begin
  select row_to_json(NEW) into v_job;

  select profile_id
  from sms.outbound_messages
  where sms.outbound_messages.id = NEW.message_id
    and sms.outbound_messages.created_at > now() - interval '1 day'
  into v_profile_id;

  select row_to_json(relevant_profile_fields)
  from (
    select
      profiles.id as profile_id,
      clients.access_token as encrypted_client_access_token,
      profiles.message_status_webhook_url,
      profiles.reply_webhook_url
    from sms.profiles 
    join billing.clients as clients on clients.id = profiles.client_id
    where sms.profiles.id = v_profile_id
  ) relevant_profile_fields
  into v_profile_json;

  select v_job::jsonb || v_profile_json::jsonb into v_job;
  perform assemble_worker.add_job('forward-delivery-report', v_job, null, 5);
  return NEW;
end;
$$;

-- This function is now only used for forward_inbound_messages, so
-- i'm removing a code path that could result in a full search on
-- outbound_messages_routing, even though this code path is not currently being run
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
    where sms.sending_locations.id = NEW.sending_location_id
  ) relevant_profile_fields
  into v_profile_json;

  select v_job::jsonb || v_profile_json::jsonb into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job, null, 5);
  return NEW;
end;
$$;

-- Limit to the current day
CREATE OR REPLACE FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[]) RETURNS public.phone_number
    LANGUAGE plpgsql
    AS $$
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
      from sms.outbound_messages_routing
      where processed_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
        and original_created_at > date_trunc('day', now())
      group by sms.outbound_messages_routing.from_number
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

DROP FUNCTION sms.update_is_current_period_indexes;

DROP INDEX sms.outbound_messages_routing_phone_number_overloaded_idx;
CREATE INDEX outbound_messages_routing_phone_number_overloaded_idx 
  ON sms.outbound_messages_routing 
  USING btree (processed_at DESC, from_number)
  INCLUDE (estimated_segments) 
  WHERE (stage <> 'awaiting-number'::sms.outbound_message_stages);

alter table sms.outbound_messages drop column is_current_period;
alter table sms.outbound_messages_routing drop column is_current_period;

DO $$ 
declare 
  v_schema_exists boolean;
begin
  -- This table may or may not exist because it's installed at runtime
  if exists (
    select 1 from information_schema.schemata where schema_name = 'graphile_scheduler'
  )
  then
    delete from graphile_scheduler.schedules
    where schedule_name = 'update-is-current-period-indexes';
  end if;
end
$$;

-- Include a now() on the insert instead of using the column default
CREATE OR REPLACE FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code DEFAULT NULL::text, send_before timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS sms.outbound_messages
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_client_id uuid;
  v_profile_id uuid;
  v_contact_zip_code zip_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  select billing.current_client_id() into v_client_id;

  if v_client_id is null then
    raise 'Not authorized';
  end if;

  select id
  from sms.profiles
  where client_id = v_client_id
    and id = send_message.profile_id
  into v_profile_id;

  if v_profile_id is null then
    raise 'Profile % not found – it may not exist, or you may not have access', send_message.profile_id using errcode = 'no_data_found';
  end if;

  if contact_zip_code is null or contact_zip_code = '' then
    select sms.map_area_code_to_zip_code(sms.extract_area_code(send_message.to)) into v_contact_zip_code;
  else
    select contact_zip_code into v_contact_zip_code;
  end if;

  select sms.estimate_segments(body) into v_estimated_segments;

  insert into sms.outbound_messages (profile_id, created_at, to_number, stage, body, media_urls, contact_zip_code, estimated_segments, send_before)
  values (send_message.profile_id, date_trunc('second', now()), send_message.to, 'processing', body, media_urls, v_contact_zip_code, v_estimated_segments, send_message.send_before)
  returning *
  into v_result;

  return v_result;
end;
$$;
