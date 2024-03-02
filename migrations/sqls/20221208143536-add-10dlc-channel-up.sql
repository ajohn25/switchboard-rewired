-- Add check to profiles
-- ------------------------------------

alter table sms.profiles
  add constraint valid_10dlc_channel check ( channel <> '10dlc' or tendlc_campaign_id is not null );


-- Update outbound message trigger
-- ------------------------------------

create or replace function sms.tg__trigger_process_message() returns trigger as $$
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
    perform assemble_worker.add_job('process-grey-route-message', v_job, null, 5);
  elsif v_channel = 'toll-free'::sms.traffic_channel then
    perform assemble_worker.add_job('process-toll-free-message', v_job, null, 5);
  elsif v_channel = '10dlc'::sms.traffic_channel then
    perform assemble_worker.add_job('process-10dlc-message', v_job, null, 5);
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$ language plpgsql;


-- Update profile provisioned trigger
-- ------------------------------------

CREATE OR REPLACE FUNCTION sms.tg__sync_profile_provisioned() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
declare
  v_profile_ids uuid[];
begin
  update sms.profiles
  set
    provisioned = exists (
      select 1
      from sms.sending_locations
      where
        profile_id = profiles.id
        and decomissioned_at is null
    )
  where
    id = ANY(array[OLD.profile_id, NEW.profile_id])
    and channel in ('grey-route', '10dlc');

  return NEW;
end;
$$;


-- Add 10DLC process-message
-- ------------------------------------

create or replace function sms.process_10dlc_message(message sms.outbound_messages, prev_mapping_validity_interval interval DEFAULT '14 days'::interval)
  returns json
  as $$
declare
  v_channel sms.traffic_channel;
  v_sending_location_id uuid;
  v_prev_mapping_from_number phone_number;
  v_prev_mapping_created_at timestamp;
  v_prev_mapping_first_send_of_day boolean;
  v_from_number phone_number;
  v_result record;
begin
  select channel
  from sms.profiles
  where id = message.profile_id
  limit 1
  into
      v_channel
    , v_from_number;

  if v_channel <> '10dlc' then
    raise exception 'Profile is not 10dlc channel: %', message.profile_id;
  end if;


  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number, last_used_at, sending_location_id
  from sms.active_from_number_mappings
  where to_number = message.to_number
    and profile_id = message.profile_id
    and (
      cordoned_at is null
      or cordoned_at > now() - interval '3 days'
      or last_used_at > now() - interval '3 days'
    )
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
      first_from_to_pair_of_day,
      profile_id
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
      v_prev_mapping_first_send_of_day,
      message.profile_id
    )
    returning *
    into v_result;

    return row_to_json(v_result);
  end if;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  -- We expect exactly one phone number per sending location
  select pn.phone_number
  from sms.phone_numbers pn
  join sms.sending_locations sl on sl.id = pn.sending_location_id
  where sl.id = v_sending_location_id
  limit 1
  into v_from_number;

  if v_from_number is null then
    raise exception 'No 10dlc number for profile: %, sending location %', message.profile_id, v_sending_location_id;
  end if;

  insert into sms.outbound_messages_routing (
      id
    , original_created_at
    , from_number
    , to_number
    , stage
    , sending_location_id
    , decision_stage
    , processed_at
    , profile_id
  )
  values (
      message.id
    , message.created_at
    , v_from_number
    , message.to_number
    , 'queued'
    , v_sending_location_id
    , 'prev_mapping'
    , now()
    , message.profile_id
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$ language plpgsql security definer;

comment on function sms.process_10dlc_message is E'@omit';
