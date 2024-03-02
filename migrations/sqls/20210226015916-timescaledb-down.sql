/*
  Unfortunately, TimescaleDB hyptertables can't be reverted.

  The only way to restore the previous state is to drop and restore,
  which requires dropping virtually every single object in the database.

  The only reason way I thought of to accomplish this was to drop the 3
  schemas and then run a restore script.

  The restore script was generated via:
    pg_dump switchboard -s -n sms -n billing -n lookup \
    -f migrations/sqls/20210226015916-timescaledb-down.sql
  
  The beginning part was deleted, since some of those options weren't
  compatible with node-pg.

  The key part that remained is `SET check_function_bodies = false`.
*/

DROP SCHEMA sms CASCADE;
DROP SCHEMA billing CASCADE;
DROP SCHEMA lookup CASCADE;

--
-- PostgreSQL database dump
--

-- Dumped from database version 13.2
-- Dumped by pg_dump version 13.2

SET check_function_bodies = false;
--
-- Name: billing; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA billing;


ALTER SCHEMA billing OWNER TO postgres;

--
-- Name: lookup; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA lookup;


ALTER SCHEMA lookup OWNER TO postgres;

--
-- Name: sms; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA sms;


ALTER SCHEMA sms OWNER TO postgres;

--
-- Name: access_fulfillment_state; Type: TYPE; Schema: lookup; Owner: postgres
--

CREATE TYPE lookup.access_fulfillment_state AS ENUM (
    'done',
    'waiting',
    'fetching'
);


ALTER TYPE lookup.access_fulfillment_state OWNER TO postgres;

--
-- Name: billing_status_enum; Type: TYPE; Schema: lookup; Owner: postgres
--

CREATE TYPE lookup.billing_status_enum AS ENUM (
    'billed',
    'cached'
);


ALTER TYPE lookup.billing_status_enum OWNER TO postgres;

--
-- Name: phone_type_enum; Type: TYPE; Schema: lookup; Owner: postgres
--

CREATE TYPE lookup.phone_type_enum AS ENUM (
    'landline',
    'mobile',
    'voip',
    'unknown',
    'invalid'
);


ALTER TYPE lookup.phone_type_enum OWNER TO postgres;

--
-- Name: request_progress_result; Type: TYPE; Schema: lookup; Owner: postgres
--

CREATE TYPE lookup.request_progress_result AS (
	completed_at timestamp without time zone,
	progress numeric
);


ALTER TYPE lookup.request_progress_result OWNER TO postgres;

--
-- Name: service_option; Type: TYPE; Schema: lookup; Owner: postgres
--

CREATE TYPE lookup.service_option AS ENUM (
    'telnyx'
);


ALTER TYPE lookup.service_option OWNER TO postgres;

--
-- Name: delivery_report_event; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.delivery_report_event AS ENUM (
    'queued',
    'sending',
    'sent',
    'delivered',
    'sending_failed',
    'delivery_failed',
    'delivery_unconfirmed'
);


ALTER TYPE sms.delivery_report_event OWNER TO postgres;

--
-- Name: number_purchasing_strategy; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.number_purchasing_strategy AS ENUM (
    'exact-area-codes',
    'same-state-by-distance'
);


ALTER TYPE sms.number_purchasing_strategy OWNER TO postgres;

--
-- Name: outbound_message_stages; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.outbound_message_stages AS ENUM (
    'processing',
    'awaiting-number',
    'queued',
    'sent',
    'failed'
);


ALTER TYPE sms.outbound_message_stages OWNER TO postgres;

--
-- Name: profile_service_option; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.profile_service_option AS ENUM (
    'twilio',
    'telnyx'
);


ALTER TYPE sms.profile_service_option OWNER TO postgres;

--
-- Name: telco_status; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.telco_status AS ENUM (
    'sent',
    'delivered',
    'failed'
);


ALTER TYPE sms.telco_status OWNER TO postgres;

--
-- Name: telnyx_credentials; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.telnyx_credentials AS (
	public_key text,
	encrypted_api_key text,
	messaging_profile_id text
);


ALTER TYPE sms.telnyx_credentials OWNER TO postgres;

--
-- Name: twilio_credentials; Type: TYPE; Schema: sms; Owner: postgres
--

CREATE TYPE sms.twilio_credentials AS (
	account_sid text,
	encrypted_auth_token text
);


ALTER TYPE sms.twilio_credentials OWNER TO postgres;

--
-- Name: current_client_id(); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE FUNCTION billing.current_client_id() RETURNS uuid
    LANGUAGE sql STABLE
    SET search_path TO '$user', 'public'
    AS $$
  select current_setting('client.id')::uuid
$$;


ALTER FUNCTION billing.current_client_id() OWNER TO postgres;

--
-- Name: inbound_message_usage(uuid, timestamp with time zone); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE FUNCTION billing.inbound_message_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, sms_segments bigint, mms_segments bigint)
    LANGUAGE plpgsql
    AS $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(num_segments) filter (where num_media = 0) as sms_segments,
    sum(num_segments) filter (where num_media > 0) as mms_segments
  from sms.inbound_messages
  join sms.sending_locations
    on sms.sending_locations.id = sms.inbound_messages.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = client
    and sms.inbound_messages.received_at >= v_month_start
    and sms.inbound_messages.received_at < v_month_end
  group by 1, 4
  order by
    sms_segments desc;
end;
$$;


ALTER FUNCTION billing.inbound_message_usage(client uuid, month timestamp with time zone) OWNER TO postgres;

--
-- Name: lrn_usage(uuid, timestamp with time zone); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE FUNCTION billing.lrn_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, lookup_count bigint)
    LANGUAGE plpgsql
    AS $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    lookup.accesses.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    count(distinct lookup.accesses.phone_number) as lookup_count
  from lookup.accesses
  where true
    and lookup.accesses.client_id = lrn_usage.client
    and lookup.accesses.accessed_at >= v_month_start
    and lookup.accesses.accessed_at < v_month_end
    and not exists (
      select 1
      from lookup.accesses as previous_accesses
      where true
        and previous_accesses.client_id = lrn_usage.client
        and previous_accesses.phone_number = lookup.accesses.phone_number
        and previous_accesses.accessed_at < lookup.accesses.accessed_at
    )
  group by 1;
end;
$$;


ALTER FUNCTION billing.lrn_usage(client uuid, month timestamp with time zone) OWNER TO postgres;

--
-- Name: outbound_message_usage(uuid, timestamp with time zone); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE FUNCTION billing.outbound_message_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, sms_segments bigint, mms_segments bigint, queued_messages bigint)
    LANGUAGE plpgsql
    AS $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media = 0) as sms_segments,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media > 0) as mms_segments,
    count(1) filter (where stage = 'queued' or stage = 'awaiting-number') as queued_messages
  from sms.outbound_messages
  join sms.sending_locations
    on sms.sending_locations.id = sms.outbound_messages.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = client
    and sms.outbound_messages.created_at >= v_month_start
    and sms.outbound_messages.created_at < v_month_end
  group by 1, 4
  order by
    sms_segments desc;
end;
$$;


ALTER FUNCTION billing.outbound_message_usage(client uuid, month timestamp with time zone) OWNER TO postgres;

--
-- Name: phone_number_usage(uuid, timestamp with time zone); Type: FUNCTION; Schema: billing; Owner: postgres
--

CREATE FUNCTION billing.phone_number_usage(client uuid, month timestamp with time zone) RETURNS TABLE(client_id uuid, period_start timestamp with time zone, period_end timestamp with time zone, service sms.profile_service_option, number_months double precision)
    LANGUAGE plpgsql
    AS $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
  v_days_in_month int;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;
	select extract(days from v_month_start + '1 month - 1 day'::interval) into v_days_in_month;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(
      extract(day from least(v_month_end, released_at) - greatest(v_month_start, created_at)) / v_days_in_month::float
    ) as number_months  
  from sms.all_phone_numbers
  join sms.sending_locations
    on sms.sending_locations.id = sms.all_phone_numbers.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = phone_number_usage.client
    and sms.all_phone_numbers.created_at < v_month_end
    and (
      sms.all_phone_numbers.released_at is null
      or sms.all_phone_numbers.released_at >= v_month_start
    )
  group by 1, 4
  order by
    number_months desc;
end;
$$;


ALTER FUNCTION billing.phone_number_usage(client uuid, month timestamp with time zone) OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: requests; Type: TABLE; Schema: lookup; Owner: postgres
--

CREATE TABLE lookup.requests (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    client_id uuid DEFAULT billing.current_client_id() NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    closed_at timestamp without time zone,
    completed_at timestamp without time zone
);


ALTER TABLE lookup.requests OWNER TO postgres;

--
-- Name: TABLE requests; Type: COMMENT; Schema: lookup; Owner: postgres
--

COMMENT ON TABLE lookup.requests IS '
@omit update
';


--
-- Name: close_request(uuid); Type: FUNCTION; Schema: lookup; Owner: postgres
--

CREATE FUNCTION lookup.close_request(request_id uuid) RETURNS lookup.requests
    LANGUAGE plpgsql STRICT
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_request_completed boolean;
  v_result lookup.requests;
  v_request_id uuid;
begin
  select request_id into v_request_id;

  select (
    select count(*)
    from lookup.accesses
    where lookup.accesses.request_id = v_request_id
      and state <> 'done'
  ) = 0
  into v_request_completed;

  if v_request_completed then
    update lookup.requests
    set completed_at = now()
    where lookup.requests.id = v_request_id;
  end if;

  update lookup.requests
  set closed_at = now()
  where id = v_request_id;

  select * from lookup.requests
  where id = v_request_id
  into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION lookup.close_request(request_id uuid) OWNER TO postgres;

--
-- Name: request_progress(uuid); Type: FUNCTION; Schema: lookup; Owner: postgres
--

CREATE FUNCTION lookup.request_progress(request_id uuid) RETURNS lookup.request_progress_result
    LANGUAGE plpgsql
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_total_accesses int;
  v_accesses_done int;
  v_completed_at timestamp;
  v_progress numeric;
  v_requests_found int;
begin
  select count(*) from lookup.requests
  where lookup.requests.id = request_progress.request_id
  into v_requests_found;

  if v_requests_found = 0 then
    raise 'No request found' using errcode = 'no_data_found';
  end if;

  select count(*)
  from lookup.accesses
  where lookup.accesses.request_id = request_progress.request_id
  into v_total_accesses;

  select count(*)
  from lookup.accesses
  where state = 'done'
    and lookup.accesses.request_id = request_progress.request_id
  into v_accesses_done;

  select null into v_completed_at;

  if v_total_accesses - v_accesses_done = 0 then
    select now() into v_completed_at;

    update lookup.requests
    set completed_at = v_completed_at
    where lookup.requests.closed_at is not null 
      and lookup.requests.id = request_progress.request_id;
  end if;

  select (
    case when v_total_accesses = 0 then 0
    else v_accesses_done::numeric / v_total_accesses::numeric end
  ) into v_progress;
  return cast(row(v_completed_at, v_progress) as lookup.request_progress_result);
end;
$$;


ALTER FUNCTION lookup.request_progress(request_id uuid) OWNER TO postgres;

--
-- Name: tg__access__fulfill(); Type: FUNCTION; Schema: lookup; Owner: postgres
--

CREATE FUNCTION lookup.tg__access__fulfill() RETURNS trigger
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

    perform assemble_worker.add_job('lookup', v_job_json);
  else
    NEW.state = 'done';
  end if;

  return NEW;
end;
$$;


ALTER FUNCTION lookup.tg__access__fulfill() OWNER TO postgres;

--
-- Name: tg__lookup__mark_access_done(); Type: FUNCTION; Schema: lookup; Owner: postgres
--

CREATE FUNCTION lookup.tg__lookup__mark_access_done() RETURNS trigger
    LANGUAGE plpgsql STRICT
    SET search_path TO '$user', 'public'
    AS $$
begin
  update lookup.accesses
  set state = 'done'::lookup.access_fulfillment_state
  where phone_number = NEW.phone_number;

  return NEW;
end;
$$;


ALTER FUNCTION lookup.tg__lookup__mark_access_done() OWNER TO postgres;

--
-- Name: tg__lookup__update_phone_data(); Type: FUNCTION; Schema: lookup; Owner: postgres
--

CREATE FUNCTION lookup.tg__lookup__update_phone_data() RETURNS trigger
    LANGUAGE plpgsql STRICT
    SET search_path TO '$user', 'public'
    AS $$
begin
  insert into lookup.phone_data (phone_number, carrier_name, phone_type)
  values (NEW.phone_number, NEW.carrier_name, NEW.phone_type)
  on conflict (phone_number) do 
    update
    set carrier_name = NEW.carrier_name,
        phone_type = NEW.phone_type,
        last_updated_at = now();
  
  return NEW;
end;
$$;


ALTER FUNCTION lookup.tg__lookup__update_phone_data() OWNER TO postgres;

--
-- Name: backfill_commitment_buckets(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.backfill_commitment_buckets() RETURNS void
    LANGUAGE sql
    AS $$
  with values_to_write as (
    select
      from_number,
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu') as truncated_day,
      count(distinct to_number) as commitment,
      sending_location_id
    from sms.outbound_messages
    where processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
          -- can safely limit created_at since only those are relevant buckets
      and processed_at is not null
      and from_number is not null
      and stage <> 'awaiting-number'
    group by 1, 2, 4
  )
  insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment, sending_location_id)
  select from_number as phone_number, truncated_day, commitment, sending_location_id
  from values_to_write
  on conflict (truncated_day, phone_number)
  do update
  set commitment = excluded.commitment
$$;


ALTER FUNCTION sms.backfill_commitment_buckets() OWNER TO postgres;

--
-- Name: backfill_pending_request_commitment_counts(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.backfill_pending_request_commitment_counts() RETURNS void
    LANGUAGE sql
    AS $$
  with pending_number_commitment_counts as (
    select id as pending_number_request_id, coalesce(commitment_counts.commitment_count, 0) as commitment_count
    from sms.phone_number_requests
    left join (
      select count(*) as commitment_count, pending_number_request_id
      from sms.outbound_messages
      where stage = 'awaiting-number'::sms.outbound_message_stages
      group by pending_number_request_id
    ) as commitment_counts on sms.phone_number_requests.id = pending_number_request_id
    where fulfilled_at is null
  )
  update sms.phone_number_requests
  set commitment_count = pending_number_commitment_counts.commitment_count
  from pending_number_commitment_counts
  where pending_number_commitment_counts.pending_number_request_id = sms.phone_number_requests.id
$$;


ALTER FUNCTION sms.backfill_pending_request_commitment_counts() OWNER TO postgres;

--
-- Name: cascade_sending_location_decomission(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.cascade_sending_location_decomission() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  update sms.all_phone_numbers
  set released_at = NEW.decomissioned_at
  where sms.all_phone_numbers.sending_location_id = NEW.id;

  return NEW;
end;
$$;


ALTER FUNCTION sms.cascade_sending_location_decomission() OWNER TO postgres;

--
-- Name: choose_area_code_for_sending_location(uuid); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.choose_area_code_for_sending_location(sending_location_id uuid) RETURNS public.area_code
    LANGUAGE sql
    AS $$
  select area_code from (
    select area_code_options.area_code, capacity
    from (
      select unnest(area_codes) as area_code
      from sms.sending_locations
      where sms.sending_locations.id = sending_location_id
    ) area_code_options
    left join sms.area_code_capacities
      on sms.area_code_capacities.area_code = area_code_options.area_code
    order by capacity desc, area_code_options.area_code desc
    limit 1
  ) area_code_with_most_capacity
$$;


ALTER FUNCTION sms.choose_area_code_for_sending_location(sending_location_id uuid) OWNER TO postgres;

--
-- Name: FUNCTION choose_area_code_for_sending_location(sending_location_id uuid); Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON FUNCTION sms.choose_area_code_for_sending_location(sending_location_id uuid) IS '@omit';


--
-- Name: choose_existing_available_number(uuid[]); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[]) RETURNS public.phone_number
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
        and is_current_period = true
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


ALTER FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[]) OWNER TO postgres;

--
-- Name: choose_sending_location_for_contact(public.zip_code, uuid); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
declare
  v_sending_location_id uuid;
  v_from_number phone_number;
  v_contact_state text;
  v_contact_location point;
begin
  select state
  from geo.zip_locations
  where zip = contact_zip_code
  into v_contact_state;

  select location
  from geo.zip_locations
  where zip = contact_zip_code
  into v_contact_location;

  if v_contact_location is not null then
  -- Find the closest one in the same state
    select id
    from sms.sending_locations
    where state = v_contact_state
      and sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
      and decomissioned_at is null
    order by location <-> v_contact_location asc
    limit 1
    into v_sending_location_id;

    if v_sending_location_id is not null then
      return v_sending_location_id;
    end if;

    -- Find the next closest one
    select id
    from sms.sending_locations
    where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
      and decomissioned_at is null
    order by location <-> v_contact_location asc
    limit 1
    into v_sending_location_id;

    if v_sending_location_id is not null then
      return v_sending_location_id;
    end if;
  end if;

  -- Pick one with available phone numbers
  select sms.choose_existing_available_number(array_agg(id))
  from sms.sending_locations
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  into v_from_number;

  if v_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where sms.phone_numbers.phone_number = v_from_number
    into v_sending_location_id;

    return v_sending_location_id;
  end if;

  -- Pick a random one
  select id
  from sms.sending_locations
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and sms.sending_locations.decomissioned_at is null
  order by random()
  limit 1
  into v_sending_location_id;

  return v_sending_location_id;
end;
$$;


ALTER FUNCTION sms.choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid) OWNER TO postgres;

--
-- Name: FUNCTION choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid); Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON FUNCTION sms.choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid) IS '@omit';


--
-- Name: compute_sending_location_capacity(uuid); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.compute_sending_location_capacity(sending_location_id uuid) RETURNS integer
    LANGUAGE sql
    AS $$
  with sending_location_info as (
    select sms.profiles.sending_account_id, sms.sending_locations.area_codes
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.sending_locations.id = compute_sending_location_capacity.sending_location_id
    limit 1
  )
  select sum(capacity)::integer
  from sms.area_code_capacities
  where sms.area_code_capacities.sending_account_id = (
      select sending_account_id
      from sending_location_info
    )
    and area_code in ( 
      select unnest(area_codes)
      from sending_location_info
    )
$$;


ALTER FUNCTION sms.compute_sending_location_capacity(sending_location_id uuid) OWNER TO postgres;

--
-- Name: estimate_segments(text); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.estimate_segments(body text) RETURNS integer
    LANGUAGE sql IMMUTABLE
    AS $$
  select char_length(body) / 153 + 1
$$;


ALTER FUNCTION sms.estimate_segments(body text) OWNER TO postgres;

--
-- Name: extract_area_code(public.phone_number); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.extract_area_code(phone_number public.phone_number) RETURNS public.area_code
    LANGUAGE sql
    AS $$
  select substring(phone_number from 3 for 3)::area_code
$$;


ALTER FUNCTION sms.extract_area_code(phone_number public.phone_number) OWNER TO postgres;

--
-- Name: FUNCTION extract_area_code(phone_number public.phone_number); Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON FUNCTION sms.extract_area_code(phone_number public.phone_number) IS '@omit';


--
-- Name: increment_commitment_bucket_if_unique(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.increment_commitment_bucket_if_unique() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
declare
  v_already_recorded boolean;
begin
  insert into sms.fresh_phone_commitments (phone_number, commitment, sending_location_id)
  values (NEW.from_number, 1, NEW.sending_location_id)
  on conflict (phone_number)
  do update
  set commitment = sms.fresh_phone_commitments.commitment + 1;

  return NEW;
end;
$$;


ALTER FUNCTION sms.increment_commitment_bucket_if_unique() OWNER TO postgres;

--
-- Name: map_area_code_to_zip_code(public.area_code); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.map_area_code_to_zip_code(area_code public.area_code) RETURNS public.zip_code
    LANGUAGE sql
    AS $$
  select zip
  from geo.zip_area_codes
  where geo.zip_area_codes.area_code = map_area_code_to_zip_code.area_code
  limit 1
$$;


ALTER FUNCTION sms.map_area_code_to_zip_code(area_code public.area_code) OWNER TO postgres;

--
-- Name: FUNCTION map_area_code_to_zip_code(area_code public.area_code); Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON FUNCTION sms.map_area_code_to_zip_code(area_code public.area_code) IS '@omit';


--
-- Name: outbound_messages; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.outbound_messages (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    sending_location_id uuid,
    created_at timestamp without time zone DEFAULT now(),
    contact_zip_code public.zip_code NOT NULL,
    stage sms.outbound_message_stages NOT NULL,
    to_number public.phone_number NOT NULL,
    from_number public.phone_number,
    pending_number_request_id uuid,
    body text NOT NULL,
    media_urls public.url[],
    service_id text,
    num_segments integer,
    num_media integer,
    extra json,
    decision_stage text,
    estimated_segments integer DEFAULT 1,
    send_after timestamp without time zone,
    profile_id uuid,
    processed_at timestamp without time zone,
    cost_in_cents numeric(6,2),
    first_from_to_pair_of_day boolean DEFAULT true,
    send_before timestamp without time zone,
    is_current_period boolean DEFAULT true NOT NULL
)
WITH (autovacuum_vacuum_threshold='50000', autovacuum_vacuum_scale_factor='0', autovacuum_vacuum_cost_limit='1000', autovacuum_vacuum_cost_delay='0');


ALTER TABLE sms.outbound_messages OWNER TO postgres;

--
-- Name: TABLE outbound_messages; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.outbound_messages IS '@omit';


--
-- Name: outbound_messages_routing; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.outbound_messages_routing (
    id uuid NOT NULL,
    to_number public.phone_number NOT NULL,
    from_number public.phone_number,
    estimated_segments integer DEFAULT 1,
    stage sms.outbound_message_stages NOT NULL,
    decision_stage text,
    first_from_to_pair_of_day boolean DEFAULT true,
    sending_location_id uuid,
    pending_number_request_id uuid,
    send_after timestamp without time zone,
    is_current_period boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    processed_at timestamp without time zone
);


ALTER TABLE sms.outbound_messages_routing OWNER TO postgres;

--
-- Name: process_message(sms.outbound_messages, boolean, interval); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.process_message(message sms.outbound_messages, check_old_messages boolean DEFAULT false, prev_mapping_validity_interval interval DEFAULT NULL::interval) RETURNS sms.outbound_messages_routing
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
  select from_number, created_at, sending_location_id
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
    and (prev_mapping_validity_interval is null or created_at > now() - prev_mapping_validity_interval)
  order by created_at desc
  limit 1
  into v_prev_mapping_from_number, v_prev_mapping_created_at, v_sending_location_id;

  -- Check old table
  if check_old_messages is true then
    if v_prev_mapping_from_number is null then
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
        and (prev_mapping_validity_interval is null or created_at > now() - prev_mapping_validity_interval)
      order by created_at desc
      limit 1
      into v_prev_mapping_from_number, v_prev_mapping_created_at;
    end if;
  end if;

  if v_prev_mapping_from_number is not null then
    select
      v_prev_mapping_created_at <
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    into v_prev_mapping_first_send_of_day;

    insert into sms.outbound_messages_routing (
      id,
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
      from_number,
      to_number,
      stage,
      decision_stage,
      processed_at,
      sending_location_id
    )
    values (
      message.id,
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
    and sms.pending_Number_request_capacity.pending_number_request_id in (
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
      to_number,
      pending_number_request_id,
      stage,
      sending_location_id,
      decision_stage,
      processed_at
    )
    values (
      message.id,
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
    to_number,
    pending_number_request_id,
    stage,
    sending_location_id,
    decision_stage,
    processed_at
  )
  values (
    message.id,
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


ALTER FUNCTION sms.process_message(message sms.outbound_messages, check_old_messages boolean, prev_mapping_validity_interval interval) OWNER TO postgres;

--
-- Name: queue_find_suitable_area_codes_refresh(uuid); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.queue_find_suitable_area_codes_refresh(sending_location_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform assemble_worker.add_job('find-suitable-area-codes', row_to_json(all_area_code_capacity_job_info))
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


ALTER FUNCTION sms.queue_find_suitable_area_codes_refresh(sending_location_id uuid) OWNER TO postgres;

--
-- Name: refresh_area_code_capacity_estimates(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.refresh_area_code_capacity_estimates() RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform assemble_worker.add_job('estimate-area-code-capacity', row_to_json(all_area_code_capacity_job_info))
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


ALTER FUNCTION sms.refresh_area_code_capacity_estimates() OWNER TO postgres;

--
-- Name: refresh_one_area_code_capacity(public.area_code, uuid); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.refresh_one_area_code_capacity(area_code public.area_code, sending_account_id uuid) RETURNS void
    LANGUAGE plpgsql
    AS $$
begin
  perform assemble_worker.add_job('estimate-area-code-capacity', row_to_json(all_area_code_capacity_job_info))
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


ALTER FUNCTION sms.refresh_one_area_code_capacity(area_code public.area_code, sending_account_id uuid) OWNER TO postgres;

--
-- Name: reset_sending_location_state_and_locations(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.reset_sending_location_state_and_locations() RETURNS void
    LANGUAGE sql
    AS $$
  update sms.sending_locations
  set
    state = geo.zip_locations.state,
    location = geo.zip_locations.location
  from geo.zip_locations
  where sms.sending_locations.center = geo.zip_locations.zip;
$$;


ALTER FUNCTION sms.reset_sending_location_state_and_locations() OWNER TO postgres;

--
-- Name: resolve_delivery_reports(interval, interval, timestamp without time zone); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval, fire_date timestamp without time zone DEFAULT now()) RETURNS bigint
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
)
select count(*) from job_insert_result
$$;


ALTER FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval, fire_date timestamp without time zone) OWNER TO postgres;

--
-- Name: sell_cordoned_numbers(integer); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.sell_cordoned_numbers(n_days integer) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$
  with sell_result as (
    update sms.all_phone_numbers
    set sold_at = now()
    where sold_at is null
      and cordoned_at > now() - (interval '1 days' * n_days)
    returning 1
  )
  select count(*)
  from sell_result
$$;


ALTER FUNCTION sms.sell_cordoned_numbers(n_days integer) OWNER TO postgres;

--
-- Name: send_message(uuid, public.phone_number, text, public.url[], public.zip_code, timestamp without time zone); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code DEFAULT NULL::text, send_before timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS sms.outbound_messages
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

  insert into sms.outbound_messages (profile_id, to_number, stage, body, media_urls, contact_zip_code, estimated_segments, send_before)
  values (send_message.profile_id, send_message.to, 'processing', body, media_urls, v_contact_zip_code, v_estimated_segments, send_message.send_before)
  returning *
  into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) OWNER TO postgres;

--
-- Name: sending_locations; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.sending_locations (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    profile_id uuid NOT NULL,
    reference_name text NOT NULL,
    area_codes public.area_code[],
    center public.zip_code NOT NULL,
    decomissioned_at timestamp without time zone,
    purchasing_strategy sms.number_purchasing_strategy NOT NULL,
    state text,
    location point
);


ALTER TABLE sms.sending_locations OWNER TO postgres;

--
-- Name: sending_locations_active_phone_number_count(sms.sending_locations); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.sending_locations_active_phone_number_count(sl sms.sending_locations) RETURNS bigint
    LANGUAGE sql STABLE STRICT SECURITY DEFINER
    AS $$ 
  select count(*)
  from sms.phone_numbers
  where sending_location_id = sl.id
$$;


ALTER FUNCTION sms.sending_locations_active_phone_number_count(sl sms.sending_locations) OWNER TO postgres;

--
-- Name: tg__delivery_reports__find_message_id(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__delivery_reports__find_message_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_message_id uuid;
begin
  select id
  from sms.outbound_messages
  where service_id = NEW.message_service_id
  into v_message_id;

  NEW.message_id = v_message_id;
  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__delivery_reports__find_message_id() OWNER TO postgres;

--
-- Name: tg__inbound_messages__attach_to_sending_location(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__inbound_messages__attach_to_sending_location() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_sending_location_id uuid;
begin
  select sending_location_id
  from sms.phone_numbers
  where phone_number = NEW.to_number
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Could not match % to a known sending location', NEW.to_number;
  end if;

  NEW.sending_location_id = v_sending_location_id;
  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__inbound_messages__attach_to_sending_location() OWNER TO postgres;

--
-- Name: tg__outbound_messages__increment_pending_request_commitment(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
begin
  update sms.phone_number_requests
  set commitment_count = commitment_count + 1
  where id = NEW.pending_number_request_id;

  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment() OWNER TO postgres;

--
-- Name: tg__outbound_messages__update_delivery_reports_with_message_id(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__outbound_messages__update_delivery_reports_with_message_id() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  update sms.delivery_reports
  set message_id = NEW.id
  where message_service_id = NEW.service_id
    and message_id is null;
  
  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__outbound_messages__update_delivery_reports_with_message_id() OWNER TO postgres;

--
-- Name: tg__phone_number_requests__fulfill(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__phone_number_requests__fulfill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

  with interval_waits as (
    select
      id,
      to_number,
      sum(estimated_segments) over (partition by 1 order by created_at) as nth_segment
    from (
      select id, to_number, estimated_segments, created_at
      from sms.outbound_messages_routing
      where pending_number_request_id = NEW.id
        and sms.outbound_messages_routing.stage = 'awaiting-number'::sms.outbound_message_stages
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
    and interval_waits.id = sms.outbound_messages_routing.id;

  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__phone_number_requests__fulfill() OWNER TO postgres;

--
-- Name: tg__sending_locations__set_state_and_location(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__sending_locations__set_state_and_location() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_state text;
  v_location point;
begin
  select state, location
  into v_state, v_location
  from geo.zip_locations
  where zip = NEW.center;

  if v_state is null or v_location is null then
    raise 'Could not find location record for zip code %. Please try another zip code.', NEW.center;
  end if;

  NEW.state := v_state;
  NEW.location := v_location;
  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__sending_locations__set_state_and_location() OWNER TO postgres;

--
-- Name: tg__sending_locations__strategy_inherit(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__sending_locations__strategy_inherit() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_profile_purchasing_strategy sms.number_purchasing_strategy;
begin
  select default_purchasing_strategy
  from sms.profiles
  where id = NEW.profile_id
  into v_profile_purchasing_strategy;

  NEW.purchasing_strategy := v_profile_purchasing_strategy;
  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__sending_locations__strategy_inherit() OWNER TO postgres;

--
-- Name: tg__sending_locations_area_code__prefill(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.tg__sending_locations_area_code__prefill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_area_codes text[];
begin
  select array_agg(distinct area_code)
  into v_area_codes
  from geo.zip_area_codes
  where geo.zip_area_codes.zip = NEW.center;

  -- Try the next closest zip code
  if coalesce(array_length(v_area_codes, 1), 0) = 0 then
    select array_agg(distinct geo.zip_area_codes.area_code)
    into v_area_codes
    from geo.zip_area_codes
    where zip = (
      select zip
      from geo.zip_locations
      where exists (
        select area_code
        from geo.zip_area_codes
        where geo.zip_area_codes.zip = geo.zip_locations.zip
      )
      order by location <-> NEW.location asc
      limit 1
    );
  end if;

  if coalesce(array_length(v_area_codes, 1), 0) = 0 then
    raise 'Could not find area codes for sending location with zip %', NEW.center;
  end if;

  NEW.area_codes = v_area_codes;

  return NEW;
end;
$$;


ALTER FUNCTION sms.tg__sending_locations_area_code__prefill() OWNER TO postgres;

--
-- Name: trigger_send_message(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.trigger_send_message() RETURNS trigger
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


ALTER FUNCTION sms.trigger_send_message() OWNER TO postgres;

--
-- Name: update_is_current_period_indexes(); Type: FUNCTION; Schema: sms; Owner: postgres
--

CREATE FUNCTION sms.update_is_current_period_indexes() RETURNS bigint
    LANGUAGE sql STRICT
    AS $$
  select 1::bigint;
$$;


ALTER FUNCTION sms.update_is_current_period_indexes() OWNER TO postgres;

--
-- Name: clients; Type: TABLE; Schema: billing; Owner: postgres
--

CREATE TABLE billing.clients (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    name text NOT NULL,
    access_token text DEFAULT md5((random())::text),
    created_at timestamp without time zone DEFAULT now() NOT NULL
);


ALTER TABLE billing.clients OWNER TO postgres;

--
-- Name: inbound_messages; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.inbound_messages (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    sending_location_id uuid NOT NULL,
    from_number public.phone_number NOT NULL,
    to_number public.phone_number NOT NULL,
    body text NOT NULL,
    received_at timestamp without time zone NOT NULL,
    service sms.profile_service_option NOT NULL,
    service_id text NOT NULL,
    num_segments integer NOT NULL,
    num_media integer NOT NULL,
    validated boolean NOT NULL,
    media_urls public.url[],
    extra json
);


ALTER TABLE sms.inbound_messages OWNER TO postgres;

--
-- Name: TABLE inbound_messages; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.inbound_messages IS '@omit';


--
-- Name: profiles; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.profiles (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    client_id uuid DEFAULT billing.current_client_id() NOT NULL,
    sending_account_id uuid NOT NULL,
    display_name text,
    reply_webhook_url public.url NOT NULL,
    message_status_webhook_url public.url NOT NULL,
    default_purchasing_strategy sms.number_purchasing_strategy DEFAULT 'same-state-by-distance'::sms.number_purchasing_strategy NOT NULL,
    voice_callback_url text
);


ALTER TABLE sms.profiles OWNER TO postgres;

--
-- Name: TABLE profiles; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.profiles IS '@omit';


--
-- Name: sending_accounts; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.sending_accounts (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    display_name text,
    service sms.profile_service_option NOT NULL,
    twilio_credentials sms.twilio_credentials,
    telnyx_credentials sms.telnyx_credentials,
    run_cost_backfills boolean DEFAULT false
);


ALTER TABLE sms.sending_accounts OWNER TO postgres;

--
-- Name: TABLE sending_accounts; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.sending_accounts IS '@omit';


--
-- Name: past_month_inbound_sms; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE VIEW billing.past_month_inbound_sms AS
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(inbound_messages.num_segments) FILTER (WHERE (inbound_messages.num_media = 0)) AS sms_segments,
    sum(inbound_messages.num_segments) FILTER (WHERE (inbound_messages.num_media > 0)) AS mms_segments
   FROM ((((sms.inbound_messages
     JOIN sms.sending_locations ON ((sending_locations.id = inbound_messages.sending_location_id)))
     JOIN sms.profiles ON ((profiles.id = sending_locations.profile_id)))
     JOIN sms.sending_accounts ON ((sending_accounts.id = profiles.sending_account_id)))
     JOIN billing.clients ON ((clients.id = profiles.client_id)))
  WHERE ((inbound_messages.received_at >= (date_trunc('month'::text, now()) - '1 mon'::interval)) AND (inbound_messages.received_at < date_trunc('month'::text, now())))
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, sending_accounts.service;


ALTER TABLE billing.past_month_inbound_sms OWNER TO postgres;

--
-- Name: accesses; Type: TABLE; Schema: lookup; Owner: postgres
--

CREATE TABLE lookup.accesses (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    client_id uuid DEFAULT billing.current_client_id() NOT NULL,
    request_id uuid,
    phone_number public.phone_number NOT NULL,
    accessed_at timestamp without time zone DEFAULT now() NOT NULL,
    state lookup.access_fulfillment_state DEFAULT 'waiting'::lookup.access_fulfillment_state NOT NULL,
    billing_status lookup.billing_status_enum
);


ALTER TABLE lookup.accesses OWNER TO postgres;

--
-- Name: past_month_lrn_usage; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE VIEW billing.past_month_lrn_usage AS
 WITH client_counts AS (
         SELECT count(DISTINCT past_month_accesses.phone_number) AS lookup_count,
            past_month_accesses.client_id
           FROM lookup.accesses past_month_accesses
          WHERE ((date_trunc('month'::text, past_month_accesses.accessed_at) = date_trunc('month'::text, (now() - '1 mon'::interval))) AND (NOT (EXISTS ( SELECT 1
                   FROM lookup.accesses previous_accesses
                  WHERE ((date_trunc('month'::text, previous_accesses.accessed_at) < date_trunc('month'::text, (now() - '1 mon'::interval))) AND ((previous_accesses.phone_number)::text = (past_month_accesses.phone_number)::text))))))
          GROUP BY past_month_accesses.client_id
        )
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    client_counts.lookup_count
   FROM (client_counts
     JOIN billing.clients ON ((clients.id = client_counts.client_id)));


ALTER TABLE billing.past_month_lrn_usage OWNER TO postgres;

--
-- Name: all_phone_numbers; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.all_phone_numbers (
    phone_number public.phone_number NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    released_at timestamp without time zone,
    sending_location_id uuid NOT NULL,
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    sold_at timestamp without time zone,
    cordoned_at timestamp without time zone
);


ALTER TABLE sms.all_phone_numbers OWNER TO postgres;

--
-- Name: TABLE all_phone_numbers; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.all_phone_numbers IS '@omit';


--
-- Name: past_month_number_count; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE VIEW billing.past_month_number_count AS
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(
        CASE
            WHEN (all_phone_numbers.created_at < (date_trunc('month'::text, now()) - '1 mon'::interval)) THEN (1)::double precision
            ELSE (date_part('day'::text, (date_trunc('month'::text, now()) - (all_phone_numbers.created_at)::timestamp with time zone)) / date_part('day'::text, (date_trunc('month'::text, now()) - (date_trunc('month'::text, now()) - '1 mon'::interval))))
        END) AS number_months
   FROM ((((sms.all_phone_numbers
     JOIN sms.sending_locations ON ((sending_locations.id = all_phone_numbers.sending_location_id)))
     JOIN sms.profiles ON ((profiles.id = sending_locations.profile_id)))
     JOIN sms.sending_accounts ON ((sending_accounts.id = profiles.sending_account_id)))
     JOIN billing.clients ON ((clients.id = profiles.client_id)))
  WHERE ((all_phone_numbers.created_at < date_trunc('month'::text, now())) AND (all_phone_numbers.sold_at IS NULL))
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, (sum(
        CASE
            WHEN (all_phone_numbers.created_at < (date_trunc('month'::text, now()) - '1 mon'::interval)) THEN (1)::double precision
            ELSE (date_part('day'::text, (date_trunc('month'::text, now()) - (all_phone_numbers.created_at)::timestamp with time zone)) / date_part('day'::text, (date_trunc('month'::text, now()) - (date_trunc('month'::text, now()) - '1 mon'::interval))))
        END)) DESC;


ALTER TABLE billing.past_month_number_count OWNER TO postgres;

--
-- Name: past_month_outbound_sms; Type: VIEW; Schema: billing; Owner: postgres
--

CREATE VIEW billing.past_month_outbound_sms AS
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(outbound_messages.num_segments) FILTER (WHERE ((outbound_messages.stage = 'sent'::sms.outbound_message_stages) AND (outbound_messages.num_media = 0))) AS sms_segments,
    sum(outbound_messages.num_segments) FILTER (WHERE ((outbound_messages.stage = 'sent'::sms.outbound_message_stages) AND (outbound_messages.num_media > 0))) AS mms_segments,
    count(1) FILTER (WHERE ((outbound_messages.stage = 'queued'::sms.outbound_message_stages) OR (outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages))) AS queued_messages
   FROM ((((sms.outbound_messages
     JOIN sms.sending_locations ON ((sending_locations.id = outbound_messages.sending_location_id)))
     JOIN sms.profiles ON ((profiles.id = sending_locations.profile_id)))
     JOIN sms.sending_accounts ON ((sending_accounts.id = profiles.sending_account_id)))
     JOIN billing.clients ON ((clients.id = profiles.client_id)))
  WHERE ((outbound_messages.created_at >= (date_trunc('month'::text, now()) - '1 mon'::interval)) AND (outbound_messages.created_at < date_trunc('month'::text, now())))
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, sending_accounts.service;


ALTER TABLE billing.past_month_outbound_sms OWNER TO postgres;

--
-- Name: phone_data; Type: TABLE; Schema: lookup; Owner: postgres
--

CREATE TABLE lookup.phone_data (
    phone_number public.phone_number NOT NULL,
    carrier_name text,
    phone_type lookup.phone_type_enum NOT NULL,
    last_updated_at timestamp without time zone DEFAULT now()
);


ALTER TABLE lookup.phone_data OWNER TO postgres;

--
-- Name: TABLE phone_data; Type: COMMENT; Schema: lookup; Owner: postgres
--

COMMENT ON TABLE lookup.phone_data IS '@omit';


--
-- Name: fresh_phone_data; Type: VIEW; Schema: lookup; Owner: postgres
--

CREATE VIEW lookup.fresh_phone_data AS
 SELECT phone_data.phone_number,
    phone_data.carrier_name,
    phone_data.phone_type,
    phone_data.last_updated_at AS updated_at
   FROM lookup.phone_data
  WHERE ((phone_data.last_updated_at > (now() - '1 year'::interval)) AND ((CURRENT_USER = 'lookup'::name) OR (CURRENT_USER = 'postgres'::name) OR (EXISTS ( SELECT 1
           FROM lookup.accesses
          WHERE (((accesses.phone_number)::text = (phone_data.phone_number)::text) AND (accesses.accessed_at > (now() - '1 year'::interval)))))));


ALTER TABLE lookup.fresh_phone_data OWNER TO postgres;

--
-- Name: VIEW fresh_phone_data; Type: COMMENT; Schema: lookup; Owner: postgres
--

COMMENT ON VIEW lookup.fresh_phone_data IS '@omit';


--
-- Name: lookups; Type: TABLE; Schema: lookup; Owner: postgres
--

CREATE TABLE lookup.lookups (
    phone_number public.phone_number,
    performed_at timestamp without time zone DEFAULT now() NOT NULL,
    via_service lookup.service_option DEFAULT 'telnyx'::lookup.service_option NOT NULL,
    carrier_name text,
    phone_type lookup.phone_type_enum NOT NULL,
    raw_result json
);


ALTER TABLE lookup.lookups OWNER TO postgres;

--
-- Name: request_results; Type: VIEW; Schema: lookup; Owner: postgres
--

CREATE VIEW lookup.request_results AS
 SELECT accesses.request_id,
    accesses.phone_number,
    fresh_phone_data.phone_type
   FROM (lookup.accesses
     JOIN lookup.fresh_phone_data ON (((fresh_phone_data.phone_number)::text = (accesses.phone_number)::text)))
  WHERE (accesses.client_id = billing.current_client_id());


ALTER TABLE lookup.request_results OWNER TO postgres;

--
-- Name: VIEW request_results; Type: COMMENT; Schema: lookup; Owner: postgres
--

COMMENT ON VIEW lookup.request_results IS '
@foreignKey (request_id) references lookup.requests (id)
@primaryKey phone_number
';


--
-- Name: area_code_capacities; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.area_code_capacities (
    area_code public.area_code NOT NULL,
    sending_account_id uuid NOT NULL,
    capacity integer,
    last_fetched_at timestamp without time zone DEFAULT now()
);


ALTER TABLE sms.area_code_capacities OWNER TO postgres;

--
-- Name: TABLE area_code_capacities; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.area_code_capacities IS '@omit';


--
-- Name: delivery_report_forward_attempts; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.delivery_report_forward_attempts (
    message_id uuid NOT NULL,
    event_type sms.delivery_report_event NOT NULL,
    sent_at timestamp without time zone DEFAULT now() NOT NULL,
    sent_headers json NOT NULL,
    sent_body json NOT NULL,
    response_status_code integer NOT NULL,
    response_headers json NOT NULL,
    response_body text
);


ALTER TABLE sms.delivery_report_forward_attempts OWNER TO postgres;

--
-- Name: TABLE delivery_report_forward_attempts; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.delivery_report_forward_attempts IS '@omit';


--
-- Name: delivery_reports; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.delivery_reports (
    message_service_id text,
    message_id uuid,
    event_type sms.delivery_report_event NOT NULL,
    generated_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    service text NOT NULL,
    validated boolean NOT NULL,
    error_codes text[],
    extra json
)
WITH (autovacuum_vacuum_threshold='50000', autovacuum_vacuum_scale_factor='0', autovacuum_vacuum_cost_limit='1000', autovacuum_vacuum_cost_delay='0');


ALTER TABLE sms.delivery_reports OWNER TO postgres;

--
-- Name: TABLE delivery_reports; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.delivery_reports IS '@omit';


--
-- Name: fresh_phone_commitments; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.fresh_phone_commitments (
    phone_number public.phone_number NOT NULL,
    commitment integer DEFAULT 0,
    sending_location_id uuid NOT NULL
)
WITH (autovacuum_vacuum_threshold='50000', autovacuum_vacuum_scale_factor='0', autovacuum_vacuum_cost_limit='1000', autovacuum_vacuum_cost_delay='0');


ALTER TABLE sms.fresh_phone_commitments OWNER TO postgres;

--
-- Name: inbound_message_forward_attempts; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.inbound_message_forward_attempts (
    message_id uuid,
    sent_at timestamp without time zone DEFAULT now() NOT NULL,
    sent_headers json NOT NULL,
    sent_body json NOT NULL,
    response_status_code integer NOT NULL,
    response_headers json NOT NULL,
    response_body text
);


ALTER TABLE sms.inbound_message_forward_attempts OWNER TO postgres;

--
-- Name: TABLE inbound_message_forward_attempts; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.inbound_message_forward_attempts IS '@omit';


--
-- Name: outbound_messages_telco; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.outbound_messages_telco (
    id uuid NOT NULL,
    service_id text,
    telco_status sms.telco_status DEFAULT 'sent'::sms.telco_status NOT NULL,
    num_segments integer,
    num_media integer,
    cost_in_cents numeric(6,2),
    extra json
);


ALTER TABLE sms.outbound_messages_telco OWNER TO postgres;

--
-- Name: phone_number_requests; Type: TABLE; Schema: sms; Owner: postgres
--

CREATE TABLE sms.phone_number_requests (
    id uuid DEFAULT public.uuid_generate_v1mc() NOT NULL,
    sending_location_id uuid NOT NULL,
    area_code public.area_code NOT NULL,
    created_at timestamp without time zone DEFAULT now(),
    phone_number public.phone_number,
    fulfilled_at timestamp without time zone,
    commitment_count bigint DEFAULT 0,
    service_order_id text
);


ALTER TABLE sms.phone_number_requests OWNER TO postgres;

--
-- Name: TABLE phone_number_requests; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON TABLE sms.phone_number_requests IS '@omit';


--
-- Name: pending_number_request_capacity; Type: VIEW; Schema: sms; Owner: postgres
--

CREATE VIEW sms.pending_number_request_capacity AS
 SELECT phone_number_requests.id AS pending_number_request_id,
    phone_number_requests.commitment_count
   FROM sms.phone_number_requests
  WHERE (phone_number_requests.fulfilled_at IS NULL);


ALTER TABLE sms.pending_number_request_capacity OWNER TO postgres;

--
-- Name: VIEW pending_number_request_capacity; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON VIEW sms.pending_number_request_capacity IS '@omit';


--
-- Name: phone_numbers; Type: VIEW; Schema: sms; Owner: postgres
--

CREATE VIEW sms.phone_numbers AS
 SELECT all_phone_numbers.phone_number,
    all_phone_numbers.created_at,
    all_phone_numbers.sending_location_id,
    all_phone_numbers.cordoned_at
   FROM sms.all_phone_numbers
  WHERE (all_phone_numbers.released_at IS NULL);


ALTER TABLE sms.phone_numbers OWNER TO postgres;

--
-- Name: VIEW phone_numbers; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON VIEW sms.phone_numbers IS '@omit';


--
-- Name: sending_accounts_as_json; Type: VIEW; Schema: sms; Owner: postgres
--

CREATE VIEW sms.sending_accounts_as_json AS
 SELECT sending_accounts.id,
    sending_accounts.display_name,
    sending_accounts.service,
    to_json(sending_accounts.twilio_credentials) AS twilio_credentials,
    to_json(sending_accounts.telnyx_credentials) AS telnyx_credentials
   FROM sms.sending_accounts;


ALTER TABLE sms.sending_accounts_as_json OWNER TO postgres;

--
-- Name: VIEW sending_accounts_as_json; Type: COMMENT; Schema: sms; Owner: postgres
--

COMMENT ON VIEW sms.sending_accounts_as_json IS '@omit';


--
-- Name: sending_location_capacities; Type: VIEW; Schema: sms; Owner: postgres
--

CREATE VIEW sms.sending_location_capacities AS
 SELECT sending_location_area_codes.id,
    sending_location_area_codes.profile_id,
    sending_location_area_codes.reference_name,
    sending_location_area_codes.center,
    sending_location_area_codes.sending_account_id,
    sending_location_area_codes.sending_account_name,
    sending_location_area_codes.area_code,
    area_code_capacities.capacity
   FROM (( SELECT sending_locations.id,
            sending_locations.profile_id,
            sending_locations.reference_name,
            sending_locations.center,
            profiles.sending_account_id,
            sending_accounts.display_name AS sending_account_name,
            unnest(sending_locations.area_codes) AS area_code
           FROM ((sms.sending_locations
             JOIN sms.profiles ON ((profiles.id = sending_locations.profile_id)))
             JOIN sms.sending_accounts ON ((sending_accounts.id = profiles.sending_account_id)))) sending_location_area_codes
     JOIN sms.area_code_capacities ON ((((area_code_capacities.area_code)::text = (sending_location_area_codes.area_code)::text) AND (area_code_capacities.sending_account_id = sending_location_area_codes.sending_account_id))));


ALTER TABLE sms.sending_location_capacities OWNER TO postgres;

--
-- Name: clients clients_access_token_key; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.clients
    ADD CONSTRAINT clients_access_token_key UNIQUE (access_token);


--
-- Name: clients clients_name_key; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.clients
    ADD CONSTRAINT clients_name_key UNIQUE (name);


--
-- Name: clients clients_pkey; Type: CONSTRAINT; Schema: billing; Owner: postgres
--

ALTER TABLE ONLY billing.clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: accesses accesses_pkey; Type: CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.accesses
    ADD CONSTRAINT accesses_pkey PRIMARY KEY (id);


--
-- Name: phone_data phone_data_pkey; Type: CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.phone_data
    ADD CONSTRAINT phone_data_pkey PRIMARY KEY (phone_number);


--
-- Name: requests requests_pkey; Type: CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.requests
    ADD CONSTRAINT requests_pkey PRIMARY KEY (id);


--
-- Name: accesses unique_phone_number_request; Type: CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.accesses
    ADD CONSTRAINT unique_phone_number_request UNIQUE (phone_number, request_id);


--
-- Name: fresh_phone_commitments fresh_phone_commitments_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.fresh_phone_commitments
    ADD CONSTRAINT fresh_phone_commitments_pkey PRIMARY KEY (phone_number);


--
-- Name: inbound_messages inbound_messages_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.inbound_messages
    ADD CONSTRAINT inbound_messages_pkey PRIMARY KEY (id);


--
-- Name: outbound_messages outbound_messages_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.outbound_messages
    ADD CONSTRAINT outbound_messages_pkey PRIMARY KEY (id);


--
-- Name: outbound_messages_telco outbound_messages_telco_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.outbound_messages_telco
    ADD CONSTRAINT outbound_messages_telco_pkey PRIMARY KEY (id);


--
-- Name: phone_number_requests phone_number_requests_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.phone_number_requests
    ADD CONSTRAINT phone_number_requests_pkey PRIMARY KEY (id);


--
-- Name: all_phone_numbers phone_numbers_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.all_phone_numbers
    ADD CONSTRAINT phone_numbers_pkey PRIMARY KEY (id);


--
-- Name: profiles profiles_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.profiles
    ADD CONSTRAINT profiles_pkey PRIMARY KEY (id);


--
-- Name: sending_accounts sending_accounts_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.sending_accounts
    ADD CONSTRAINT sending_accounts_pkey PRIMARY KEY (id);


--
-- Name: sending_locations sending_locations_pkey; Type: CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.sending_locations
    ADD CONSTRAINT sending_locations_pkey PRIMARY KEY (id);


--
-- Name: client_access_token_idx; Type: INDEX; Schema: billing; Owner: postgres
--

CREATE INDEX client_access_token_idx ON billing.clients USING btree (access_token);


--
-- Name: accessess_access_at_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX accessess_access_at_idx ON lookup.accesses USING btree (accessed_at);


--
-- Name: accessess_client_id_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX accessess_client_id_idx ON lookup.accesses USING btree (client_id);


--
-- Name: accessess_phone_number_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX accessess_phone_number_idx ON lookup.accesses USING btree (phone_number);


--
-- Name: accessess_request_id_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX accessess_request_id_idx ON lookup.accesses USING btree (request_id);


--
-- Name: phone_data_updated_at_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX phone_data_updated_at_idx ON lookup.phone_data USING btree (last_updated_at);


--
-- Name: request_client_id_idx; Type: INDEX; Schema: lookup; Owner: postgres
--

CREATE INDEX request_client_id_idx ON lookup.requests USING btree (client_id);


--
-- Name: active_phone_number_sending_location_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX active_phone_number_sending_location_idx ON sms.all_phone_numbers USING btree (sending_location_id, phone_number) WHERE (released_at IS NULL);


--
-- Name: active_sending_locations_profile_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX active_sending_locations_profile_id_idx ON sms.sending_locations USING btree (profile_id, state) WHERE (decomissioned_at IS NULL);


--
-- Name: area_code_sending_accounts_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE UNIQUE INDEX area_code_sending_accounts_idx ON sms.area_code_capacities USING btree (area_code, sending_account_id);


--
-- Name: awaiting_resolution_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX awaiting_resolution_idx ON sms.delivery_reports USING btree (created_at, message_service_id) WHERE (message_id IS NULL);


--
-- Name: choose_existing_phone_number_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX choose_existing_phone_number_idx ON sms.fresh_phone_commitments USING btree (sending_location_id, commitment DESC);


--
-- Name: delivery_report_message_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX delivery_report_message_id_idx ON sms.delivery_reports USING btree (message_id);


--
-- Name: delivery_report_service_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX delivery_report_service_id_idx ON sms.delivery_reports USING btree (message_service_id) WHERE (message_id IS NULL);


--
-- Name: delivery_reports_created_at_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX delivery_reports_created_at_idx ON sms.delivery_reports USING btree (created_at, event_type);


--
-- Name: inbound_message_forward_attempts_message_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX inbound_message_forward_attempts_message_id_idx ON sms.inbound_message_forward_attempts USING btree (message_id);


--
-- Name: inbound_messages_sending_location_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX inbound_messages_sending_location_id_idx ON sms.inbound_messages USING btree (sending_location_id);


--
-- Name: new_outbound_messages_phone_request_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX new_outbound_messages_phone_request_idx ON sms.outbound_messages USING btree (pending_number_request_id) WHERE (stage = 'awaiting-number'::sms.outbound_message_stages);


--
-- Name: outbound_message_routing_from_number_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_message_routing_from_number_idx ON sms.outbound_messages_routing USING btree (from_number);


--
-- Name: outbound_messages_routing_phone_number_overloaded_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_routing_phone_number_overloaded_idx ON sms.outbound_messages_routing USING btree (processed_at DESC, from_number) INCLUDE (estimated_segments) WHERE ((is_current_period = true) AND (stage <> 'awaiting-number'::sms.outbound_message_stages));


--
-- Name: outbound_messages_routing_previous_sent_message_query_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_routing_previous_sent_message_query_idx ON sms.outbound_messages_routing USING btree (sending_location_id, to_number, created_at DESC);


--
-- Name: outbound_messages_routing_request_fulfillment_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_routing_request_fulfillment_idx ON sms.outbound_messages_routing USING btree (pending_number_request_id) WHERE (stage = 'awaiting-number'::sms.outbound_message_stages);


--
-- Name: outbound_messages_routing_to_number_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_routing_to_number_idx ON sms.outbound_messages_routing USING btree (to_number);


--
-- Name: outbound_messages_service_id; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_service_id ON sms.outbound_messages USING btree (service_id) WHERE (service_id IS NOT NULL);


--
-- Name: outbound_messages_telco_service_id; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX outbound_messages_telco_service_id ON sms.outbound_messages_telco USING btree (service_id);


--
-- Name: phone_number_is_cordoned_partial_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX phone_number_is_cordoned_partial_idx ON sms.all_phone_numbers USING btree (cordoned_at) WHERE (released_at IS NULL);


--
-- Name: phone_number_requests_sending_location_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX phone_number_requests_sending_location_idx ON sms.phone_number_requests USING btree (sending_location_id) WHERE (fulfilled_at IS NULL);


--
-- Name: phone_numbers_phone_number_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX phone_numbers_phone_number_idx ON sms.all_phone_numbers USING btree (phone_number);


--
-- Name: profile_client_id_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX profile_client_id_idx ON sms.profiles USING btree (client_id);


--
-- Name: sending_location_distance_search_idx; Type: INDEX; Schema: sms; Owner: postgres
--

CREATE INDEX sending_location_distance_search_idx ON sms.sending_locations USING spgist (location);


--
-- Name: accesses _500_fulfill_access; Type: TRIGGER; Schema: lookup; Owner: postgres
--

CREATE TRIGGER _500_fulfill_access BEFORE INSERT ON lookup.accesses FOR EACH ROW EXECUTE FUNCTION lookup.tg__access__fulfill();


--
-- Name: lookups _500_update_phone_data; Type: TRIGGER; Schema: lookup; Owner: postgres
--

CREATE TRIGGER _500_update_phone_data AFTER INSERT ON lookup.lookups FOR EACH ROW EXECUTE FUNCTION lookup.tg__lookup__update_phone_data();


--
-- Name: lookups _500_update_related_accesses; Type: TRIGGER; Schema: lookup; Owner: postgres
--

CREATE TRIGGER _500_update_related_accesses AFTER INSERT ON lookup.lookups FOR EACH ROW EXECUTE FUNCTION lookup.tg__lookup__mark_access_done();


--
-- Name: sending_locations _200_set_state_and_location_before_insert; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _200_set_state_and_location_before_insert BEFORE INSERT ON sms.sending_locations FOR EACH ROW EXECUTE FUNCTION sms.tg__sending_locations__set_state_and_location();


--
-- Name: sending_locations _200_set_state_and_location_before_update; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _200_set_state_and_location_before_update BEFORE UPDATE ON sms.sending_locations FOR EACH ROW WHEN (((new.center)::text <> (old.center)::text)) EXECUTE FUNCTION sms.tg__sending_locations__set_state_and_location();


--
-- Name: inbound_messages _500_attach_sending_location; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_attach_sending_location BEFORE INSERT ON sms.inbound_messages FOR EACH ROW EXECUTE FUNCTION sms.tg__inbound_messages__attach_to_sending_location();


--
-- Name: sending_locations _500_cascade_sending_location_decomission; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_cascade_sending_location_decomission AFTER UPDATE ON sms.sending_locations FOR EACH ROW WHEN (((old.decomissioned_at IS NULL) AND (new.decomissioned_at IS NOT NULL))) EXECUTE FUNCTION sms.cascade_sending_location_decomission();


--
-- Name: sending_locations _500_choose_default_area_codes_on_sending_location; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_choose_default_area_codes_on_sending_location BEFORE INSERT ON sms.sending_locations FOR EACH ROW WHEN ((COALESCE(array_length(new.area_codes, 1), 0) = 0)) EXECUTE FUNCTION sms.tg__sending_locations_area_code__prefill();


--
-- Name: all_phone_numbers _500_decomission_phone_number; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_decomission_phone_number AFTER UPDATE ON sms.all_phone_numbers FOR EACH ROW WHEN (((old.released_at IS NULL) AND (new.released_at IS NOT NULL))) EXECUTE FUNCTION public.trigger_sell_number();


--
-- Name: sending_locations _500_find_suitable_area_codes; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_find_suitable_area_codes AFTER INSERT ON sms.sending_locations FOR EACH ROW WHEN ((new.purchasing_strategy = 'same-state-by-distance'::sms.number_purchasing_strategy)) EXECUTE FUNCTION public.trigger_job_with_sending_account_info('find-suitable-area-codes');


--
-- Name: inbound_messages _500_forward_inbound_message; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_forward_inbound_message AFTER INSERT ON sms.inbound_messages FOR EACH ROW EXECUTE FUNCTION public.trigger_job_with_profile_info('forward-inbound-message');


--
-- Name: delivery_reports _500_foward_delivery_report; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_foward_delivery_report AFTER INSERT ON sms.delivery_reports FOR EACH ROW WHEN ((new.message_id IS NOT NULL)) EXECUTE FUNCTION public.trigger_forward_delivery_report_with_profile_info();


--
-- Name: outbound_messages_routing _500_increment_commitment_bucket_after_insert; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_increment_commitment_bucket_after_insert AFTER INSERT ON sms.outbound_messages_routing FOR EACH ROW WHEN (((new.from_number IS NOT NULL) AND (new.first_from_to_pair_of_day = true))) EXECUTE FUNCTION sms.increment_commitment_bucket_if_unique();


--
-- Name: outbound_messages_routing _500_increment_commitment_bucket_after_update; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_increment_commitment_bucket_after_update AFTER UPDATE ON sms.outbound_messages_routing FOR EACH ROW WHEN (((old.from_number IS NULL) AND (new.from_number IS NOT NULL) AND (new.first_from_to_pair_of_day = true))) EXECUTE FUNCTION sms.increment_commitment_bucket_if_unique();


--
-- Name: outbound_messages_routing _500_increment_pending_request_commitment_after_insert; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_increment_pending_request_commitment_after_insert AFTER INSERT ON sms.outbound_messages_routing FOR EACH ROW WHEN ((new.pending_number_request_id IS NOT NULL)) EXECUTE FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment();


--
-- Name: outbound_messages_routing _500_increment_pending_request_commitment_after_update; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_increment_pending_request_commitment_after_update AFTER UPDATE ON sms.outbound_messages_routing FOR EACH ROW WHEN (((new.pending_number_request_id IS NOT NULL) AND (old.pending_number_request_id IS NULL))) EXECUTE FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment();


--
-- Name: sending_locations _500_inherit_purchasing_strategy; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_inherit_purchasing_strategy BEFORE INSERT ON sms.sending_locations FOR EACH ROW WHEN ((new.purchasing_strategy IS NULL)) EXECUTE FUNCTION sms.tg__sending_locations__strategy_inherit();


--
-- Name: phone_number_requests _500_poll_number_order_for_readiness; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_poll_number_order_for_readiness AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (((old.service_order_id IS NULL) AND (new.service_order_id IS NOT NULL))) EXECUTE FUNCTION public.trigger_job_with_sending_account_info('poll-number-order');


--
-- Name: outbound_messages _500_process_outbound_message; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_process_outbound_message AFTER INSERT ON sms.outbound_messages FOR EACH ROW WHEN ((new.stage = 'processing'::sms.outbound_message_stages)) EXECUTE FUNCTION public.trigger_job('process-message');


--
-- Name: phone_number_requests _500_purchase_number; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_purchase_number AFTER INSERT ON sms.phone_number_requests FOR EACH ROW EXECUTE FUNCTION public.trigger_job_with_sending_account_and_profile_info('purchase-number');


--
-- Name: sending_locations _500_queue_determine_area_code_capacity_after_insert; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_queue_determine_area_code_capacity_after_insert AFTER INSERT ON sms.sending_locations FOR EACH ROW WHEN (((new.area_codes IS NOT NULL) AND (array_length(new.area_codes, 1) > 0) AND (new.purchasing_strategy = 'exact-area-codes'::sms.number_purchasing_strategy))) EXECUTE FUNCTION public.trigger_job_with_sending_account_info('estimate-area-code-capacity');


--
-- Name: sending_locations _500_queue_determine_area_code_capacity_after_update; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_queue_determine_area_code_capacity_after_update AFTER UPDATE ON sms.sending_locations FOR EACH ROW WHEN (((old.area_codes <> new.area_codes) AND (array_length(new.area_codes, 1) > 0) AND (new.purchasing_strategy = 'exact-area-codes'::sms.number_purchasing_strategy))) EXECUTE FUNCTION public.trigger_job_with_sending_account_info('estimate-area-code-capacity');


--
-- Name: phone_number_requests _500_queue_messages_after_fulfillment; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_queue_messages_after_fulfillment AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (((old.fulfilled_at IS NULL) AND (new.fulfilled_at IS NOT NULL) AND (new.phone_number IS NOT NULL))) EXECUTE FUNCTION sms.tg__phone_number_requests__fulfill();


--
-- Name: outbound_messages_routing _500_send_message_after_fulfillment; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_send_message_after_fulfillment AFTER UPDATE ON sms.outbound_messages_routing FOR EACH ROW WHEN (((old.stage = 'awaiting-number'::sms.outbound_message_stages) AND (new.stage = 'queued'::sms.outbound_message_stages))) EXECUTE FUNCTION sms.trigger_send_message();


--
-- Name: outbound_messages_routing _500_send_message_after_process; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_send_message_after_process AFTER UPDATE ON sms.outbound_messages_routing FOR EACH ROW WHEN (((new.stage = 'queued'::sms.outbound_message_stages) AND (old.stage = 'processing'::sms.outbound_message_stages))) EXECUTE FUNCTION sms.trigger_send_message();


--
-- Name: outbound_messages_routing _500_send_message_basic; Type: TRIGGER; Schema: sms; Owner: postgres
--

CREATE TRIGGER _500_send_message_basic AFTER INSERT ON sms.outbound_messages_routing FOR EACH ROW WHEN ((new.stage = 'queued'::sms.outbound_message_stages)) EXECUTE FUNCTION sms.trigger_send_message();


--
-- Name: accesses accesses_client_id_fkey; Type: FK CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.accesses
    ADD CONSTRAINT accesses_client_id_fkey FOREIGN KEY (client_id) REFERENCES billing.clients(id);


--
-- Name: accesses accesses_request_id_fkey; Type: FK CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.accesses
    ADD CONSTRAINT accesses_request_id_fkey FOREIGN KEY (request_id) REFERENCES lookup.requests(id);


--
-- Name: requests requests_client_id_fkey; Type: FK CONSTRAINT; Schema: lookup; Owner: postgres
--

ALTER TABLE ONLY lookup.requests
    ADD CONSTRAINT requests_client_id_fkey FOREIGN KEY (client_id) REFERENCES billing.clients(id);


--
-- Name: area_code_capacities area_code_capacities_sending_account_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.area_code_capacities
    ADD CONSTRAINT area_code_capacities_sending_account_id_fkey FOREIGN KEY (sending_account_id) REFERENCES sms.sending_accounts(id);


--
-- Name: delivery_reports delivery_reports_message_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.delivery_reports
    ADD CONSTRAINT delivery_reports_message_id_fkey FOREIGN KEY (message_id) REFERENCES sms.outbound_messages(id);


--
-- Name: fresh_phone_commitments fresh_phone_commitments_sending_location_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.fresh_phone_commitments
    ADD CONSTRAINT fresh_phone_commitments_sending_location_id_fkey FOREIGN KEY (sending_location_id) REFERENCES sms.sending_locations(id) ON DELETE CASCADE;


--
-- Name: inbound_message_forward_attempts inbound_message_forward_attempts_message_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.inbound_message_forward_attempts
    ADD CONSTRAINT inbound_message_forward_attempts_message_id_fkey FOREIGN KEY (message_id) REFERENCES sms.inbound_messages(id);


--
-- Name: inbound_messages inbound_messages_sending_location_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.inbound_messages
    ADD CONSTRAINT inbound_messages_sending_location_id_fkey FOREIGN KEY (sending_location_id) REFERENCES sms.sending_locations(id);


--
-- Name: outbound_messages outbound_messages_pending_number_request_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.outbound_messages
    ADD CONSTRAINT outbound_messages_pending_number_request_id_fkey FOREIGN KEY (pending_number_request_id) REFERENCES sms.phone_number_requests(id);


--
-- Name: outbound_messages outbound_messages_sending_location_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.outbound_messages
    ADD CONSTRAINT outbound_messages_sending_location_id_fkey FOREIGN KEY (sending_location_id) REFERENCES sms.sending_locations(id);


--
-- Name: outbound_messages_telco outbound_messages_telco_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.outbound_messages_telco
    ADD CONSTRAINT outbound_messages_telco_id_fkey FOREIGN KEY (id) REFERENCES sms.outbound_messages(id) ON DELETE CASCADE;


--
-- Name: phone_number_requests phone_number_requests_sending_location_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.phone_number_requests
    ADD CONSTRAINT phone_number_requests_sending_location_id_fkey FOREIGN KEY (sending_location_id) REFERENCES sms.sending_locations(id);


--
-- Name: all_phone_numbers phone_numbers_sending_location_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.all_phone_numbers
    ADD CONSTRAINT phone_numbers_sending_location_id_fkey FOREIGN KEY (sending_location_id) REFERENCES sms.sending_locations(id);


--
-- Name: profiles profiles_client_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.profiles
    ADD CONSTRAINT profiles_client_id_fkey FOREIGN KEY (client_id) REFERENCES billing.clients(id);


--
-- Name: profiles profiles_sending_account_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.profiles
    ADD CONSTRAINT profiles_sending_account_id_fkey FOREIGN KEY (sending_account_id) REFERENCES sms.sending_accounts(id);


--
-- Name: sending_locations sending_locations_profile_id_fkey; Type: FK CONSTRAINT; Schema: sms; Owner: postgres
--

ALTER TABLE ONLY sms.sending_locations
    ADD CONSTRAINT sending_locations_profile_id_fkey FOREIGN KEY (profile_id) REFERENCES sms.profiles(id);


--
-- Name: clients; Type: ROW SECURITY; Schema: billing; Owner: postgres
--

ALTER TABLE billing.clients ENABLE ROW LEVEL SECURITY;

--
-- Name: clients clients_policy; Type: POLICY; Schema: billing; Owner: postgres
--

CREATE POLICY clients_policy ON billing.clients TO client USING ((id = billing.current_client_id()));


--
-- Name: accesses accesess_policy; Type: POLICY; Schema: lookup; Owner: postgres
--

CREATE POLICY accesess_policy ON lookup.accesses TO client USING ((client_id = billing.current_client_id()));


--
-- Name: accesses; Type: ROW SECURITY; Schema: lookup; Owner: postgres
--

ALTER TABLE lookup.accesses ENABLE ROW LEVEL SECURITY;

--
-- Name: requests; Type: ROW SECURITY; Schema: lookup; Owner: postgres
--

ALTER TABLE lookup.requests ENABLE ROW LEVEL SECURITY;

--
-- Name: requests requests_policy; Type: POLICY; Schema: lookup; Owner: postgres
--

CREATE POLICY requests_policy ON lookup.requests TO client USING ((client_id = billing.current_client_id()));


--
-- Name: all_phone_numbers; Type: ROW SECURITY; Schema: sms; Owner: postgres
--

ALTER TABLE sms.all_phone_numbers ENABLE ROW LEVEL SECURITY;

--
-- Name: all_phone_numbers client_phone_numbers_policy; Type: POLICY; Schema: sms; Owner: postgres
--

CREATE POLICY client_phone_numbers_policy ON sms.all_phone_numbers TO client USING ((EXISTS ( SELECT 1
   FROM sms.sending_locations
  WHERE (sending_locations.id = all_phone_numbers.sending_location_id)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM sms.sending_locations
  WHERE (sending_locations.id = all_phone_numbers.sending_location_id))));


--
-- Name: profiles client_profile_policy; Type: POLICY; Schema: sms; Owner: postgres
--

CREATE POLICY client_profile_policy ON sms.profiles FOR SELECT TO client USING ((client_id = billing.current_client_id()));


--
-- Name: sending_locations client_sending_location_policy; Type: POLICY; Schema: sms; Owner: postgres
--

CREATE POLICY client_sending_location_policy ON sms.sending_locations TO client USING ((EXISTS ( SELECT 1
   FROM sms.profiles
  WHERE (profiles.id = sending_locations.profile_id)))) WITH CHECK ((EXISTS ( SELECT 1
   FROM sms.profiles
  WHERE (profiles.id = sending_locations.profile_id))));


--
-- Name: profiles; Type: ROW SECURITY; Schema: sms; Owner: postgres
--

ALTER TABLE sms.profiles ENABLE ROW LEVEL SECURITY;

--
-- Name: sending_locations; Type: ROW SECURITY; Schema: sms; Owner: postgres
--

ALTER TABLE sms.sending_locations ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA billing; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA billing TO client;


--
-- Name: SCHEMA lookup; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA lookup TO client;


--
-- Name: SCHEMA sms; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA sms TO client;


--
-- Name: FUNCTION current_client_id(); Type: ACL; Schema: billing; Owner: postgres
--

GRANT ALL ON FUNCTION billing.current_client_id() TO client;


--
-- Name: TABLE requests; Type: ACL; Schema: lookup; Owner: postgres
--

GRANT SELECT,INSERT,UPDATE ON TABLE lookup.requests TO client;


--
-- Name: FUNCTION send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone); Type: ACL; Schema: sms; Owner: postgres
--

GRANT ALL ON FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) TO client;


--
-- Name: TABLE sending_locations; Type: ACL; Schema: sms; Owner: postgres
--

GRANT SELECT,INSERT,REFERENCES,TRIGGER ON TABLE sms.sending_locations TO client;


--
-- Name: TABLE clients; Type: ACL; Schema: billing; Owner: postgres
--

GRANT SELECT ON TABLE billing.clients TO client;


--
-- Name: TABLE profiles; Type: ACL; Schema: sms; Owner: postgres
--

GRANT SELECT ON TABLE sms.profiles TO client;


--
-- Name: TABLE accesses; Type: ACL; Schema: lookup; Owner: postgres
--

GRANT SELECT,INSERT ON TABLE lookup.accesses TO client;


--
-- Name: TABLE all_phone_numbers; Type: ACL; Schema: sms; Owner: postgres
--

GRANT SELECT ON TABLE sms.all_phone_numbers TO client;


--
-- Name: TABLE fresh_phone_data; Type: ACL; Schema: lookup; Owner: postgres
--

GRANT SELECT ON TABLE lookup.fresh_phone_data TO client;


--
-- Name: TABLE request_results; Type: ACL; Schema: lookup; Owner: postgres
--

GRANT SELECT ON TABLE lookup.request_results TO client;


--
-- Name: TABLE sending_accounts_as_json; Type: ACL; Schema: sms; Owner: postgres
--

GRANT SELECT ON TABLE sms.sending_accounts_as_json TO client;


--
-- PostgreSQL database dump complete
--

