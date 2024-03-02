DROP VIEW sms.pending_number_request_capacity;
CREATE VIEW sms.pending_number_request_capacity AS
 SELECT phone_number_requests.id AS pending_number_request_id,
    phone_number_requests.commitment_count
   FROM sms.phone_number_requests
  WHERE (phone_number_requests.fulfilled_at IS NULL);

comment on view sms.pending_number_request_capacity is E'@omit';

DROP VIEW sms.phone_numbers;
CREATE VIEW sms.phone_numbers AS
 SELECT all_phone_numbers.phone_number,
    all_phone_numbers.created_at,
    all_phone_numbers.sending_location_id,
    all_phone_numbers.cordoned_at
   FROM sms.all_phone_numbers
  WHERE (all_phone_numbers.released_at IS NULL);

comment on view sms.phone_numbers is E'@omit';

alter table sms.phone_number_requests drop column daily_contact_limit;
alter table sms.phone_number_requests drop column throughput_interval;
alter table sms.phone_number_requests drop column throughput_limit;

alter table sms.all_phone_numbers drop column daily_contact_limit;
alter table sms.all_phone_numbers drop column throughput_interval;
alter table sms.all_phone_numbers drop column throughput_limit;

alter table sms.fresh_phone_commitments drop column daily_contact_limit;
alter table sms.fresh_phone_commitments drop column throughput_interval;
alter table sms.fresh_phone_commitments drop column throughput_limit;

CREATE OR REPLACE FUNCTION sms.backfill_commitment_buckets() RETURNS void
    LANGUAGE sql
    AS $$
  with values_to_write as (
    select
      from_number,
      count(distinct to_number) as commitment,
      sending_location_id
    from sms.outbound_messages
    where processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
          -- can safely limit created_at since only those are relevant buckets
      and processed_at is not null
      and from_number is not null
      and stage <> 'awaiting-number'
    group by 1, 3
  )
  insert into sms.fresh_phone_commitments (
    phone_number,
    commitment,
    sending_location_id
  )
  select
    values_to_write.from_number as phone_number,
    values_to_write.commitment,
    values_to_write.sending_location_id
  from values_to_write
  join sms.phone_numbers phone_numbers on phone_numbers.phone_number = values_to_write.from_number
    and phone_numbers.sending_location_id = values_to_write.sending_location_id
  on conflict (phone_number)
  do update
  set commitment = excluded.commitment
$$;

DROP FUNCTION sms.choose_existing_available_number;
CREATE OR REPLACE FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[], profile_daily_contact_limit integer default 200, profile_throughput_limit integer default 6) RETURNS public.phone_number
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
    and commitment <= profile_daily_contact_limit
    and phone_number not in (
      select from_number
      from recent_segment_counts
      where estimated_segments >= profile_throughput_limit
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

CREATE OR REPLACE FUNCTION sms.increment_commitment_bucket_if_unique() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
declare
  v_commitment_phone phone_number;
begin
  update sms.fresh_phone_commitments
  set commitment = commitment + 1
  where phone_number = NEW.from_number
  returning phone_number
  into v_commitment_phone;

  if v_commitment_phone is null then
    insert into sms.fresh_phone_commitments (
      phone_number,
      commitment,
      sending_location_id
    )
    select
      NEW.from_number,
      1,
      NEW.sending_location_id
    from sms.profiles
    where
      id = (
        select profile_id from sms.sending_locations where id = NEW.sending_location_id
      )
    on conflict (phone_number) do update
      set commitment = sms.fresh_phone_commitments.commitment + 1;
  end if;

  return NEW;
end;
$$;

CREATE OR REPLACE FUNCTION sms.process_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT '14 days'::interval) RETURNS sms.outbound_messages_routing
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
  v_daily_contact_limit integer;
  v_throughput_interval interval;
  v_throughput_limit integer;
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
    and (original_created_at > 'now'::timestamp - prev_mapping_validity_interval)
  order by original_created_at desc
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

  select daily_contact_limit, throughput_interval, throughput_limit
  into v_daily_contact_limit, v_throughput_interval, v_throughput_limit
  from sms.profiles
  where id = message.profile_id;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select sms.choose_existing_available_number(ARRAY[v_sending_location_id], v_daily_contact_limit, v_throughput_limit)
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
  where commitment_count < v_daily_contact_limit
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

  insert into sms.phone_number_requests (
    sending_location_id,
    area_code
  )
  values (
    v_sending_location_id,
    v_area_code
  )
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

CREATE OR REPLACE FUNCTION sms.tg__phone_number_requests__fulfill() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_throughput_interval interval;
  v_throughput_limit integer;
  v_sending_account_id uuid;
  v_capacity integer;
  v_purchasing_strategy sms.number_purchasing_strategy;
begin
  -- Create the phone number record
  insert into sms.phone_numbers (
    sending_location_id,
    phone_number
  )
  values (
    NEW.sending_location_id,
    NEW.phone_number
  );

  select sending_account_id, throughput_interval, throughput_limit
  from sms.profiles profiles
  join sms.sending_locations locations on locations.profile_id = profiles.id
  where locations.id = NEW.sending_location_id
  into v_sending_account_id, v_throughput_interval, v_throughput_limit;

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
      send_after = now() + ((interval_waits.nth_segment / v_throughput_limit) * v_throughput_interval)
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

CREATE OR REPLACE FUNCTION attach_10dlc_campaign_to_profile(profile_id uuid, campaign_identifier text) returns boolean as $$
declare
  v_sending_account_json jsonb;
  v_overallocated_count bigint;
  v_overallocated_sending_location_id uuid;
begin
  update sms.profiles
  set service_10dlc_campaign_id = campaign_identifier,
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
      assemble_worker.add_job('associate-service-10dlc-campaign', row_to_json(job_payloads))
    from (
      select 
        sa.id as sending_account_id,
        sa.service as service,
        p.id as profile_id,
        p.service_profile_id,
        p.service_10dlc_campaign_id,
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
$$ language plpgsql security definer;
