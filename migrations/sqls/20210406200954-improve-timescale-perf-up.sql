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
  with recent_segment_counts as (
    select sum(estimated_segments) as estimated_segments, from_number
    from sms.outbound_messages_routing
    where processed_at > now() - '1 minute'::interval
      and stage <> 'awaiting-number'
      and original_created_at > date_trunc('day', now())
    group by sms.outbound_messages_routing.from_number
  )
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and commitment <= daily_contact_limit
    and phone_number not in (
      select from_number
      from recent_segment_counts
      where estimated_segments >= throughput_limit
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

alter table sms.all_phone_numbers add constraint only_one_minute_interval
  check (
    throughput_interval = '1 minute'::interval
  );

-- Add profile_id to send-message payload
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
      sms.profiles.id as profile_id,
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

-- Note - if migrating this on an existing timescale instance, do:
-- alter table sms.outbound_messages_telco add column profile_id uuid;
-- 
-- deploy the updated worker codebase
-- 
-- call sms.backfill_teclo_profile_id();
-- 
-- wait for it to complete
-- 
-- alter table sms.outbound_messages_telco alter column profile_id set not null;
create or replace procedure sms.backfill_telco_profile_id(starting_day timestamp default null) as $$ 
declare
  v_day timestamp;
  v_updated_count bigint;
begin
  if starting_day is null then
    select date_trunc('day', min(created_at))
    from sms.outbound_messages
    into v_day;
  else
    select starting_day
    into v_day;
  end if;

  while v_day < 'now' loop
    with update_result as (
      update sms.outbound_messages_telco telco
      set profile_id = main.profile_id
      from sms.outbound_messages main
      where main.id = telco.id
        and main.created_at = telco.original_created_at
        and main.created_at >= date_trunc('day', v_day)
        and main.created_at < date_trunc('day', v_day) + '1 day'::interval
        and main.original_created_at >= date_trunc('day', v_day)
        and main.original_created_at < date_trunc('day', v_day) + '1 day'::interval
      returning 1
    )
    select count(*)
    from update_result
    into v_updated_count;

    raise notice 'Updated %s messages on %s', v_updated_count, v_day;

    select v_day + '1 day'::interval
    into v_day;
  end loop;
end; $$ language plpgsql;

alter table sms.outbound_messages_telco add column profile_id uuid not null;

CREATE OR REPLACE FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval, fire_date timestamp without time zone DEFAULT now(), send_delay_window interval DEFAULT '1 day'::interval) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$ 
with update_result as (
  update sms.delivery_reports
  set message_id = (
    select id
    from sms.outbound_messages_telco
    where sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
      and sms.outbound_messages_telco.service_id = sms.delivery_reports.message_service_id
  )
  where sms.delivery_reports.message_id is null
    and sms.delivery_reports.created_at >= fire_date - as_far_back_as
    and sms.delivery_reports.created_at <= fire_date - as_recent_as
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
    sms.outbound_messages_telco.profile_id as profile_id,
    clients.access_token as encrypted_client_access_token,
    profiles.message_status_webhook_url,
    profiles.reply_webhook_url,
    (
      coalesce(update_result.extra, '{}'::json)::jsonb || json_build_object(
        'num_segments', sms.outbound_messages_telco.num_segments,
        'num_media', sms.outbound_messages_telco.num_media
      )::jsonb
    )::json as extra
  from update_result
  join sms.outbound_messages_telco
    on update_result.message_id = sms.outbound_messages_telco.id
  join sms.profiles as profiles on profiles.id = sms.outbound_messages_telco.profile_id
  join billing.clients as clients on clients.id = profiles.client_id
  where sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
),
job_insert_result as (
  select graphile_worker.add_job(
    identifier => 'forward-delivery-report',
    payload => row_to_json(payloads),
    priority => 100,
    max_attempts => 6
  )
  from payloads
)
select count(*) from job_insert_result
$$;
