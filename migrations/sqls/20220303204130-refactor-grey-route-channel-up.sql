-- Add Profile columns and defaults
-- ------------------------------------

create type sms.traffic_channel as enum (
  'grey-route'
);


alter table sms.profiles
  add column channel sms.traffic_channel,
  add column provisioned boolean default false,
  add column disabled boolean not null default false;

-- Backfill profile provisioned-ness
update sms.profiles
set
  channel = 'grey-route',
  provisioned = exists (
    select 1
    from sms.sending_locations
    where
      profile_id = profiles.id
      and decomissioned_at is null
  );

alter table sms.profiles
  alter column channel set not null,
  alter column provisioned set not null,
  add column active boolean generated always as (provisioned and not disabled) stored;

comment on column sms.profiles.provisioned is E'@omit create,update\nThis is true when all subresources necessary to send using the profile have also been fully provisioned.';


-- Sync grey-route provisioned status
-- ------------------------------------

create or replace function sms.tg__sync_profile_provisioned() returns trigger as $$
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
    and channel = 'grey-route';

  return NEW;
end;
$$ language plpgsql;

create trigger _700_sync_profile_provisioned
  after insert or update or delete
  on sms.sending_locations
  for each row
  execute function sms.tg__sync_profile_provisioned();

create trigger _700_sync_profile_provisioned_after_update
  after update
  on sms.sending_locations
  for each row
  when (OLD.decomissioned_at is distinct from NEW.decomissioned_at)
  execute function sms.tg__sync_profile_provisioned();


-- Prevent updating sending location profile
-- -----------------------------------------

create or replace function sms.tg__prevent_update_sending_location_profile() returns trigger as $$
begin
  raise exception 'updates to a sending location''s profile are not allowed';
end;
$$ language plpgsql;

create trigger _200_prevent_update_profile
  after update
  on sms.sending_locations
  for each row
  when (OLD.profile_id <> NEW.profile_id)
  execute function sms.tg__prevent_update_sending_location_profile();


-- Rename process_message
-- ------------------------------------

alter function sms.process_message rename to process_grey_route_message;


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
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$ language plpgsql;

drop trigger _500_process_outbound_message on sms.outbound_messages;
create trigger _500_process_outbound_message
  after insert
  on sms.outbound_messages
  for each row
  when (new.stage = 'processing'::sms.outbound_message_stages)
  execute function sms.tg__trigger_process_message();


-- Update send_message
-- ------------------------------------

CREATE OR REPLACE FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code DEFAULT NULL::text, send_before timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS sms.outbound_messages
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
declare
  v_client_id uuid;
  v_profile_id uuid;
  v_profile_active boolean;
  v_contact_zip_code zip_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  select billing.current_client_id() into v_client_id;

  if v_client_id is null then
    raise 'Not authorized';
  end if;

  select id, active
  from sms.profiles
  where client_id = v_client_id
    and id = send_message.profile_id
  into v_profile_id, v_profile_active;

  if v_profile_id is null then
    raise 'Profile % not found – it may not exist, or you may not have access', send_message.profile_id using errcode = 'no_data_found';
  end if;

  if v_profile_active is distinct from true then
    raise 'Profile % is inactive', send_message.profile_id;
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


ALTER FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) OWNER TO postgres;

GRANT ALL ON FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) TO client;
