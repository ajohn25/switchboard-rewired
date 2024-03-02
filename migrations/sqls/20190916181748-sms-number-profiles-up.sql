create schema sms;
create schema geo;

create domain url as text check (VALUE ~* '(https?:\/\/)?([\w\-])+\.{1}([a-zA-Z]{2,63})([\/\w-]*)*\/?\??([^#\n\r]*)?#?([^\n\r]*)');
create domain slug as text check (VALUE ~* '[a-z0-9\-]+');
create domain area_code as text check (VALUE ~* '[0-9]{3}');
create domain zip_code as text check (VALUE ~* '[0-9]{5}');
create domain us_state as text check (VALUE ~* '[A-Z]{2}');

create type sms.outbound_message_stages as enum (
  'processing',
  'awaiting-number',
  'queued',
  'sent',
  'failed'
);

create type sms.profile_service_option as enum (
  'twilio',
  'telnyx'
);

/*
 * telnyx uses "queued", "sending", "sent", "delivered", "sending_failed", "delivery_failed", "delivery_unconfirmed"
 * twilio uses "Accepted", "Queued", "Sent", "Delivered", "Undelivered", "Failed"
 * twilio(Failed) = telnyx(sending_failed)
 * telnyx(Undelivered) = telnyx(delivery_failed)
 *
 * I think telnyx's are good and decriptive here
 */

create type sms.delivery_report_event as enum (
  'queued',
  'sending',
  'sent',
  'delivered',
  'sending_failed',
  'delivery_failed',
  'delivery_unconfirmed'
);

-- auth_token should be symmetrically encrypted
create type sms.twilio_credentials as (
  account_sid text,
  encrypted_auth_token text
);

-- api_key should be symmetrically encrypted
create type sms.telnyx_credentials as (
  public_key text,
  encrypted_api_key text,
  messaging_profile_id text
);

-- Containts duplicate entries for each pair of zips within 25 miles of each other
create table geo.zip_proximity (
  zip1 zip_code not null,
  zip1_state us_state not null,
  zip2 zip_code not null,
  zip2_state us_state not null,
  distance_in_miles decimal not null
);

comment on table geo.zip_proximity is E'@omit';

create index zip_proximity_idx on geo.zip_proximity (zip1, zip2_state, zip2, zip2_state, distance_in_miles desc);

-- Some zip codes have many area codes - for those, there will be duplicate entries
-- Duplicate entries offer faster indexed lookup by area_code (most common use case is finding a zip for a number to text)
create table geo.zip_area_codes (
  zip zip_code not null,
  area_code area_code not null
);

comment on table geo.zip_area_codes is E'@omit';

create index zip_area_codes_idx on geo.zip_area_codes (zip, area_code);

create table sms.sending_accounts (
  id uuid primary key default uuid_generate_v1mc(),
  display_name text,
  service sms.profile_service_option not null,
  twilio_credentials sms.twilio_credentials,
  telnyx_credentials sms.telnyx_credentials
);

comment on table sms.sending_accounts is E'@omit';

-- Used to determine what area codes to buy for a sending location
-- Buy highest capacity first
create table sms.area_code_capacities (
  area_code area_code not null,
  sending_account_id uuid not null references sms.sending_accounts(id),
  capacity integer,
  last_fetched_at timestamp default now()
);

comment on table sms.area_code_capacities is E'@omit';

create unique index area_code_sending_accounts_idx on sms.area_code_capacities (area_code, sending_account_id);

create view sms.sending_accounts_as_json as
  select id, display_name, service,
    to_json(twilio_credentials) as twilio_credentials,
    to_json(telnyx_credentials) as telnyx_credentials
  from sms.sending_accounts;

comment on view sms.sending_accounts_as_json is E'@omit';

-- for twilio, service_key = account_sid and service_secret is an encrypted auth token
-- for telnyx, service_key is blank, and service_secret  
create table sms.profiles (
  id uuid primary key default uuid_generate_v1mc(),
  client_id uuid not null references billing.clients(id) default billing.current_client_id(),
  sending_account_id uuid not null references sms.sending_accounts(id),
  reference_name slug not null,
  display_name text,
  reply_webhook_url url not null,
  message_status_webhook_url url not null
);

comment on table sms.profiles is E'@omit';

create unique index client_reference_name_uniq_idx on sms.profiles (client_id, reference_name);
create index profile_client_id_idx on sms.profiles (client_id);

create table sms.sending_locations (
  id uuid primary key default uuid_generate_v1mc(),
  profile_id uuid not null references sms.profiles(id),
  reference_name text not null,
  area_codes area_code[],
  center zip_code not null
);

create index sending_location_profile_id_idx on sms.sending_locations (profile_id);

create table sms.phone_numbers (
  phone_number phone_number primary key,
  created_at timestamp not null default now(),
  released_at timestamp,
  sending_location_id uuid not null references sms.sending_locations(id)
);

comment on table sms.phone_numbers is E'
@name sendingPhoneNumbers
@omit create,update,delete
';

create table sms.phone_number_requests (
  id uuid primary key default uuid_generate_v1mc(),
  sending_location_id uuid not null references sms.sending_locations(id),
  area_code area_code not null,
  created_at timestamp default now(),
  phone_number phone_number,
  fulfilled_at timestamp
);

comment on table sms.phone_number_requests is E'@omit';

create index phone_number_requests_sending_location_idx on sms.phone_number_requests (sending_location_id) where fulfilled_at is null; 

create table sms.outbound_messages (
  id uuid primary key default uuid_generate_v1mc(),
  sending_location_id uuid not null references sms.sending_locations(id),
  created_at timestamp default now(),
  contact_zip_code zip_code not null,
  stage sms.outbound_message_stages not null,
  to_number phone_number not null,
  from_number phone_number references sms.phone_numbers(phone_number),
  pending_number_request_id uuid references sms.phone_number_requests(id),
  body text not null,
  media_urls url[],
  service_id text,
  num_segments integer,
  num_media integer,
  extra json
);

comment on table sms.outbound_messages is E'@omit';

create index outbound_messages_request_fulfillment_idx on sms.outbound_messages (pending_number_request_id) where stage = 'awaiting-number'::sms.outbound_message_stages;
create index outbound_messages_previous_sent_message_query_idx on sms.outbound_messages (sending_location_id, to_number, created_at desc);
create index outbound_messages_service_id on sms.outbound_messages (service_id);

create table sms.inbound_messages (
  id uuid primary key default uuid_generate_v1mc(),
  sending_location_id uuid not null references sms.sending_locations(id),
  from_number phone_number not null,
  to_number phone_number not null references sms.phone_numbers(phone_number),
  body text not null,
  received_at timestamp not null,
  service sms.profile_service_option not null,
  service_id text not null,
  num_segments integer not null,
  num_media integer not null,
  validated boolean not null,
  media_urls url[],
  extra json
);

comment on table sms.inbound_messages is E'@omit';

create index inbound_messages_sending_location_id_idx on sms.inbound_messages (sending_location_id);

/*  Log of reply delivery attempts by Switchboard to Switchboard client */
create table sms.inbound_message_forward_attempts (
  message_id uuid references sms.inbound_messages(id),
  sent_at timestamp not null default now(),
  sent_headers json not null,
  sent_body json not null,
  response_status_code integer not null,
  response_headers json not null,
  response_body text
);

comment on table sms.inbound_message_forward_attempts is E'@omit';

/* These may come in before the actual message sending is done, so message_service_id shouldnt have foreign key constraints */
create table sms.delivery_reports (
  message_service_id text not null,
  message_id uuid references sms.outbound_messages(id),
  event_type sms.delivery_report_event not null,
  generated_at timestamp not null, -- for twilio, this is generate on webhook receipt - no timestamp is included
  created_at timestamp not null default now(),
  service text not null,
  validated boolean not null,
  error_codes text[],
  extra json
);

comment on table sms.delivery_reports is E'@omit';

-- If we have message_id, we don't need message_service_id – this will keep searches for messages to forward fast
create index delivery_report_service_id_idx on sms.delivery_reports (message_service_id) where (message_id is null);
create index delivery_report_message_id_idx on sms.delivery_reports (message_id);

/*  Log of delivery report delivery attempts by Switchboard to Switchboard client */
create table sms.delivery_report_forward_attempts (
  message_id uuid not null,
  event_type sms.delivery_report_event not null,
  sent_at timestamp not null default now(),
  sent_headers json not null,
  sent_body json not null,
  response_status_code integer not null,
  response_headers json not null,
  response_body text
);

comment on table sms.delivery_report_forward_attempts is E'@omit';

create view sms.phone_number_capacity as
  select count(distinct to_number) as commitment_count, from_number
  from sms.outbound_messages
  group by from_number
  union
  select 0 as commitment_count, phone_number
  from sms.phone_numbers
  where not exists (
    select 1
    from sms.outbound_messages
    where sms.outbound_messages.from_number = sms.phone_numbers.phone_number
  );

comment on view sms.phone_number_capacity is E'@omit';

create view sms.pending_number_request_capacity as
  select id as pending_number_request_id, coalesce(commitment_counts.commitment_count, 0) as commitment_count
  from sms.phone_number_requests
  left join (
    select count(*) as commitment_count, pending_number_request_id
    from sms.outbound_messages
    where stage = 'awaiting-number'::sms.outbound_message_stages
    group by pending_number_request_id
  ) as commitment_counts on sms.phone_number_requests.id = pending_number_request_id
  where fulfilled_at is null;

comment on view sms.pending_number_request_capacity is E'@omit';

create function sms.extract_area_code (phone_number phone_number) returns area_code as $$
  select substring(phone_number from 3 for 3)::area_code
$$ language sql;

comment on function sms.extract_area_code is E'@omit';

create function sms.map_area_code_to_zip_code(area_code area_code) returns zip_code as $$
  select zip
  from geo.zip_area_codes
  where geo.zip_area_codes.area_code = map_area_code_to_zip_code.area_code
  limit 1
$$ language sql;

comment on function sms.map_area_code_to_zip_code is E'@omit';

create function sms.choose_area_code_for_sending_location(sending_location_id uuid) returns area_code as $$
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
$$ language sql;

comment on function sms.choose_area_code_for_sending_location is E'@omit';

create or replace function sms.choose_sending_location_for_contact(contact_zip_code zip_code, profile_id uuid) returns uuid as $$
declare
  v_sending_location_id uuid;
  v_contact_state text;
begin
  select zip1_state
  from geo.zip_proximity
  where zip1 = contact_zip_code
  into v_contact_state;

  -- Try to find a close one in the same state
  select id
  from sms.sending_locations
  join ( 
    select zip1, min(distance_in_miles) as distance
    from geo.zip_proximity
    where zip1_state = v_contact_state
      and zip2_state = v_contact_state
      and zip2 = contact_zip_code
    group by zip1
  ) as zp on zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
  order by distance asc
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Try to find anyone in the same state
  select id
  from sms.sending_locations
  join geo.zip_proximity on geo.zip_proximity.zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
    and geo.zip_proximity.zip1_state = v_contact_state
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Try to find a close one
  select id
  from sms.sending_locations
  join ( 
    select zip1, min(distance_in_miles) as distance
    from geo.zip_proximity
    where zip2 = contact_zip_code
    group by zip1
  ) as zp on zip1 = sms.sending_locations.center
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
  order by distance asc
  limit 1
  into v_sending_location_id;

  if v_sending_location_id is not null then
    return v_sending_location_id;
  end if;

  -- Pick one at random
  select id
  from sms.sending_locations
  where sms.sending_locations.profile_id = choose_sending_location_for_contact.profile_id
  order by random()
  limit 1
  into v_sending_location_id;

  return v_sending_location_id;
end;
$$ language plpgsql;

comment on function sms.choose_sending_location_for_contact is E'@omit';

create function sms.send_message (profile_name text, "to" phone_number, body text, media_urls url[], contact_zip_code zip_code default null) returns sms.outbound_messages as $$
declare
  v_client_id uuid;
  v_profile_id uuid;
  v_previous_sent_message sms.outbound_messages;
  v_sending_location_id uuid;
  v_contact_zip_code zip_code;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_result sms.outbound_messages;
begin
  select billing.current_client_id() into v_client_id;

  if v_client_id is null then
    raise 'Not authorized';
  end if;

  select id
  from sms.profiles
  where client_id = v_client_id
    and reference_name = profile_name
  into v_profile_id;

  if v_profile_id is null then
    raise 'Profile % not found – it may not exist, or you may not have access', profile_name using errcode = 'no_data_found';
  end if;

  if contact_zip_code is null then
    select sms.map_area_code_to_zip_code(sms.extract_area_code(send_message.to)) into v_contact_zip_code;
  else
    select contact_zip_code into v_contact_zip_code;
  end if;

  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select *
  from sms.outbound_messages
  where to_number = send_message.to
    and sending_location_id in (
      select id
      from sms.sending_locations
      where profile_id = v_profile_id
    )
  order by created_at desc
  limit 1
  into v_previous_sent_message;

  if v_previous_sent_message is not null then
    select from_number from v_previous_sent_message into v_from_number;
    select sending_location_id from v_previous_sent_message into v_sending_location_id; 

    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls)
    values (send_message.to, v_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls)
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(v_contact_zip_code, v_profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select from_number
  from sms.phone_number_capacity
  where commitment_count < 200
    and from_number in (
      select phone_number
      from sms.phone_numbers
      where sending_location_id = v_sending_location_id
    ) 
  order by commitment_count asc
  limit 1
  into v_from_number;

  if v_from_number is not null then
    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls)
    values (send_message.to, v_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls)
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
    insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls)
    values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls)
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

  insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls)
  values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls)
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

create or replace function sms.tg__phone_number_requests__fulfill() returns trigger as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number)
  on conflict (phone_number) do nothing;

  update sms.outbound_messages
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages
  where pending_number_request_id = NEW.id
    and sms.outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages;
  
  return NEW;
end;
$$ language plpgsql;

create trigger _500_queue_messages_after_fulfillment
  after update
  on sms.phone_number_requests
  for each row
  when (OLD.fulfilled_at is null and NEW.fulfilled_at is not null and NEW.phone_number is not null)
  execute procedure sms.tg__phone_number_requests__fulfill();

create or replace function sms.tg__sending_locations_area_code__prefill() returns trigger as $$
declare
  v_area_codes text[];
begin
  select array_agg(area_code)
  from geo.zip_area_codes
  where geo.zip_area_codes.zip = NEW.center
  into v_area_codes;

  NEW.area_codes = v_area_codes;

  return NEW;
end;
$$ language plpgsql;

create or replace function sms.tg__inbound_messages__attach_to_sending_location() returns trigger as $$
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
$$ language plpgsql;

create trigger _500_attach_sending_location
  before insert
  on sms.inbound_messages
  for each row
  execute procedure sms.tg__inbound_messages__attach_to_sending_location();

create or replace function sms.tg__outbound_messages__update_delivery_reports_with_message_id() returns trigger as $$
begin
  update sms.delivery_reports
  set message_id = NEW.id
  where message_service_id = NEW.service_id
    and message_id is null;
  
  return NEW;
end;
$$ language plpgsql;

create trigger _500_update_delivery_reports_with_message_id
  after update
  on sms.outbound_messages
  for each row
  when (NEW.service_id is not null and OLD.service_id is null)
  execute procedure sms.tg__outbound_messages__update_delivery_reports_with_message_id();

create or replace function sms.tg__delivery_reports__find_message_id() returns trigger as $$
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
$$ language plpgsql;

create trigger _500_find_message_id
  before insert
  on sms.delivery_reports
  for each row
  when (NEW.message_id is null)
  execute procedure sms.tg__delivery_reports__find_message_id();

create or replace function trigger_job() returns trigger as $$
declare
  v_job json;
begin
  select row_to_json(NEW) into v_job;
  perform assemble_worker.add_job(TG_ARGV[0], v_job);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

create or replace function trigger_job_with_sending_account_info() returns trigger as $$
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
  perform assemble_worker.add_job(TG_ARGV[0], v_job);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

create or replace function trigger_job_with_profile_info() returns trigger as $$
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
  perform assemble_worker.add_job(TG_ARGV[0], v_job);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

create trigger _500_send_message_basic
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.stage = 'queued'::sms.outbound_message_stages)
  execute procedure trigger_job_with_sending_account_info('send-message');

create trigger _500_send_message_after_fulfillment
  after update
  on sms.outbound_messages
  for each row
  when (OLD.stage = 'awaiting-number'::sms.outbound_message_stages and NEW.stage = 'queued'::sms.outbound_message_stages)
  execute procedure trigger_job_with_sending_account_info('send-message');

create trigger _500_purchase_number
  after insert
  on sms.phone_number_requests
  for each row
  execute procedure trigger_job_with_sending_account_info('purchase-number');

create trigger _500_choose_default_area_codes_on_sending_location
  before insert
  on sms.sending_locations
  for each row
  when (NEW.area_codes is null)
  execute procedure sms.tg__sending_locations_area_code__prefill();

create trigger _500_queue_determine_area_code_capacity_after_update
  after update
  on sms.sending_locations
  for each row
  when (OLD.area_codes <> NEW.area_codes and array_length(NEW.area_codes, 1) > 0)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');

create trigger _500_queue_determine_area_code_capacity_after_insert
  after insert
  on sms.sending_locations
  for each row
  when (NEW.area_codes is not null and array_length(NEW.area_codes, 1) > 0)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');

create trigger _500_forward_inbound_message
  after insert
  on sms.inbound_messages
  for each row
  execute procedure trigger_job_with_profile_info('forward-inbound-message');

create trigger _500_foward_delivery_report
  after insert
  on sms.delivery_reports
  for each row
  when (NEW.message_id is not null)
  execute procedure trigger_job_with_profile_info('forward-delivery-report');

create trigger _500_forward_delivery_report
  after update
  on sms.delivery_reports
  for each row
  when (NEW.message_id is not null and OLD.message_id is null)
  execute procedure trigger_job_with_profile_info('forward-delivery-report');

/**
 * RBAC
 */

create policy phone_numbers_policy
  on sms.phone_numbers
  to client
  using (sending_location_id in (
    select sms.sending_locations.id
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.profiles.client_id = billing.current_client_id()
  ));

create policy sending_locations_policy
  on sms.sending_locations
  to client
  using (id in (
    select sms.sending_locations.id
    from sms.sending_locations
    join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
    where sms.profiles.client_id = billing.current_client_id()
  ));

grant usage on schema sms to client;
grant usage on schema geo to client;
grant select on geo.zip_proximity to client;
grant select on geo.zip_area_codes to client;

grant select on sms.phone_numbers to client;
grant select on sms.profiles to client;
grant select on sms.sending_accounts_as_json to client;

grant all on sms.sending_locations to client;
grant execute on function sms.send_message to client;
