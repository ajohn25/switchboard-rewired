-- Update sms.refresh_area_code_capacity_estimates
-- ------------------------------------------------------------

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
    perform graphile_worker.add_job(
      identifier => 'send-message',
      payload => v_job,
      run_at => NEW.send_after,
      max_attempts => 5
    );
  else
    perform graphile_worker.add_job(
      identifier => 'send-message',
      payload => v_job,
      run_at => NEW.send_after,
      max_attempts => 5,
      flags => ARRAY['send-message-mms:global']
    );
  end if;

  return NEW;
end;
$$;


-- Update sms.tg__trigger_process_message
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION sms.tg__trigger_process_message() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_channel sms.traffic_channel;
  v_job json;
begin
  select coalesce(channel, 'grey-route'::sms.traffic_channel)
  from sms.profiles
  where id = NEW.profile_id
  into v_channel;

  select row_to_json(NEW) into v_job;

  if v_channel = 'grey-route'::sms.traffic_channel then
    perform graphile_worker.add_job(identifier => 'process-grey-route-message', payload => v_job, run_at => null, max_attempts => 5);
  elsif v_channel = 'toll-free'::sms.traffic_channel then
    perform graphile_worker.add_job(identifier => 'process-toll-free-message', payload => v_job, run_at => null, max_attempts => 5);
  elsif v_channel = '10dlc'::sms.traffic_channel then
    perform graphile_worker.add_job(identifier => 'process-10dlc-message', payload => v_job, run_at => null, max_attempts => 5);
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$;


-- Update sms.refresh_one_area_code_capacity
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION sms.refresh_one_area_code_capacity(area_code public.area_code, sending_account_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform graphile_worker.add_job(identifier => 'estimate-area-code-capacity', payload => row_to_json(all_area_code_capacity_job_info))
  from (
    select
      sms.area_code_capacities.sending_account_id,
      ARRAY[sms.area_code_capacities.area_code] as area_codes,
      sms.sending_accounts.service,
      sms.sending_accounts.twilio_credentials,
      sms.sending_accounts.telnyx_credentials
    from sms.area_code_capacities
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.area_code_capacities.sending_account_id
    where sms.sending_accounts.id = refresh_one_area_code_capacity.sending_account_id
      and sms.area_code_capacities.area_code = refresh_one_area_code_capacity.area_code
  ) as all_area_code_capacity_job_info;
end;
$$;


-- Update sms.refresh_area_code_capacity_estimates
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION sms.refresh_area_code_capacity_estimates() RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform graphile_worker.add_job(identifier => 'estimate-area-code-capacity', payload => row_to_json(all_area_code_capacity_job_info))
  from (
    select
      sms.area_code_capacities.sending_account_id,
      ARRAY[sms.area_code_capacities.area_code] as area_codes,
      sms.sending_accounts.service,
      sms.sending_accounts.twilio_credentials,
      sms.sending_accounts.telnyx_credentials
    from sms.area_code_capacities
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.area_code_capacities.sending_account_id
  ) as all_area_code_capacity_job_info;
end;
$$;


-- Update sms.queue_find_suitable_area_codes_refresh
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION sms.queue_find_suitable_area_codes_refresh(sending_location_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform graphile_worker.add_job(identifier => 'find-suitable-area-codes', payload => row_to_json(all_area_code_capacity_job_info))
  from (
    select
      sms.sending_locations.*,
      sms.sending_accounts.id as sending_account_id,
      sms.sending_accounts.service,
      sms.sending_accounts.twilio_credentials,
      sms.sending_accounts.telnyx_credentials
    from sms.sending_locations
    join sms.profiles
      on sms.sending_locations.profile_id = sms.profiles.id
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = sending_location_id
    limit 1
  ) as all_area_code_capacity_job_info;
end;
$$;


-- Update public.trigger_job_with_sending_account_info
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trigger_job_with_sending_account_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
  v_sending_account_json json;
begin
  select row_to_json(NEW) into v_job;

  if TG_TABLE_NAME = 'sending_locations' then
    v_sending_account_json := to_json(sending_account_info(NEW.id));
  else
    v_sending_account_json := to_json(sending_account_info(NEW.sending_location_id));
  end if;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform graphile_worker.add_job(identifier => TG_ARGV[0], payload => v_job, run_at => null, max_attempts => 5);
  return NEW;
end;
$$;


-- Update public.trigger_job_with_profile_info
-- ------------------------------------------------------------

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
  perform graphile_worker.add_job(identifier => TG_ARGV[0], payload => v_job, run_at => null, max_attempts => 8);
  return NEW;
end;
$$;


-- Update public.trigger_job
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.trigger_job() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
begin
  select row_to_json(NEW) into v_job;
  perform graphile_worker.add_job(identifier => TG_ARGV[0], payload => v_job, run_at => null, max_attempts => 5);
  return NEW;
end;
$$;


-- Update public.attach_10dlc_campaign_to_profile
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.attach_10dlc_campaign_to_profile(profile_id uuid, campaign_identifier text) RETURNS boolean
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_tendlc_campaign_id uuid;
  v_sending_account_json jsonb;
  v_overallocated_count bigint;
  v_overallocated_sending_location_id uuid;
begin
  with payload as (
    select
      sending_account_id as registrar_account_id,
      attach_10dlc_campaign_to_profile.campaign_identifier as registrar_campaign_id
    from sms.profiles
    where id = attach_10dlc_campaign_to_profile.profile_id
  )
  insert into sms.tendlc_campaigns (registrar_account_id, registrar_campaign_id)
  select registrar_account_id, registrar_campaign_id
  from payload
  returning id
  into v_tendlc_campaign_id;

  update sms.profiles
  set
    tendlc_campaign_id = v_tendlc_campaign_id,
    throughput_limit = 4500, -- from 75 per second
    daily_contact_limit = 3000000 -- 75 per second
  where id = attach_10dlc_campaign_to_profile.profile_id;

  -- cordon all except 1 number per sending location
  update sms.all_phone_numbers
  set cordoned_at = now()
  where sms.all_phone_numbers.id <> (
      select id
      from sms.all_phone_numbers do_not_cordon
      where do_not_cordon.sending_location_id = sms.all_phone_numbers.sending_location_id
      order by phone_number asc
      limit 1
    )
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = attach_10dlc_campaign_to_profile.profile_id
    );

  with jobs_added as (
    select
      sending_location_id,
      graphile_worker.add_job(identifier => 'associate-service-10dlc-campaign', payload => row_to_json(job_payloads))
    from (
      select
        sa.id as sending_account_id,
        sa.service as service,
        p.id as profile_id,
        p.tendlc_campaign_id,
        p.voice_callback_url,
        sa.twilio_credentials,
        sa.telnyx_credentials,
        pnr.sending_location_id,
        pnr.area_code,
        pnr.created_at,
        pnr.phone_number,
        pnr.commitment_count,
        pnr.service_order_id
      from sms.all_phone_numbers pn
      join sms.phone_number_requests pnr on pn.phone_number = pnr.phone_number
        and pnr.sending_location_id = pn.sending_location_id
      join sms.sending_locations sl on sl.id = pn.sending_location_id
      join sms.profiles p on sl.profile_id = p.id
      join sms.sending_accounts sa on p.sending_account_id = sa.id
      where pn.cordoned_at is null
        and p.id = attach_10dlc_campaign_to_profile.profile_id
    ) job_payloads
  )
  select count(*), sending_location_id
  from jobs_added
  group by 2
  having count(*) > 1
  into v_overallocated_count, v_overallocated_sending_location_id;

  -- if it's 0, that's ok, we'll associate the number when we buy it
  -- if it's more than 1, something went wrong with the above query
  if v_overallocated_count is not null and v_overallocated_sending_location_id is not null then
    raise 'error: too many numbers allocated to 10DLC campaign - % on %',
      v_overallocated_count, v_overallocated_sending_location_id;
  end if;

  return true;
end;
$$;


-- Update lookup.tg__access__fulfill
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION lookup.tg__access__fulfill() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_fresh_record_exists boolean;
  v_already_fetching boolean;
  v_job_json json;
begin
  select exists(
    select 1
    from lookup.fresh_phone_data
    where 
      lookup.fresh_phone_data.phone_number = NEW.phone_number
  ) into v_fresh_record_exists;

  select exists(
    select 1
    from lookup.accesses
    where phone_number = NEW.phone_number
      and state <> 'done'
  ) into v_already_fetching;

  if not (v_fresh_record_exists or v_already_fetching) then
    select json_build_object(
      'access_id', NEW.id,
      'phone_number', NEW.phone_number
    ) into v_job_json;

    perform graphile_worker.add_job(identifier => 'lookup', payload => v_job_json);
  else
    NEW.state = 'done';
  end if;

  return NEW;
end;
$$;


-- Update public.add_job_with_sending_account_and_profile_info
-- ------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.add_job_with_sending_account_and_profile_info(job_name text, core_payload json, param_sending_location_id uuid DEFAULT NULL::uuid) RETURNS void
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

  perform graphile_worker.add_job(identifier => job_name, payload => v_job);
end;
$$;