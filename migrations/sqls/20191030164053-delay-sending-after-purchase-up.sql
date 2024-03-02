create or replace function sms.estimate_segments (body text) returns integer as $$
  select char_length(body) / 160
$$ language sql immutable;

alter table sms.outbound_messages add column estimated_segments integer default 1;
alter table sms.outbound_messages add column send_after timestamp;

create or replace function sms.tg__phone_number_requests__fulfill() returns trigger as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number)
  on conflict (phone_number) do nothing;

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
$$ language plpgsql;

create or replace function sms.trigger_send_message() returns trigger as $$
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
  perform assemble_worker.add_job('send-message', v_job, NEW.send_after);
  return NEW;
end;
$$ language plpgsql strict set search_path from current security definer;

drop trigger _500_send_message_basic on sms.outbound_messages;
create trigger _500_send_message_basic
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.stage = 'queued'::sms.outbound_message_stages)
  execute procedure sms.trigger_send_message();

drop trigger _500_send_message_after_fulfillment on sms.outbound_messages;
create trigger _500_send_message_after_fulfillment
  after update
  on sms.outbound_messages
  for each row
  when (OLD.stage = 'awaiting-number'::sms.outbound_message_stages and NEW.stage = 'queued'::sms.outbound_message_stages)
  execute procedure sms.trigger_send_message();

drop function sms.send_message;

create or replace function sms.send_message (profile_id uuid, "to" phone_number, body text, media_urls url[], contact_zip_code zip_code default null) returns sms.outbound_messages as $$
declare
  v_client_id uuid;
  v_profile_id uuid;
  v_sending_location_id uuid;
  v_contact_zip_code zip_code;
  v_prev_from_number phone_number;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
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

  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number
  from sms.outbound_messages
  where to_number = send_message.to
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = v_profile_id
    )
  order by created_at desc
  limit 1
  into v_prev_from_number;

  if v_prev_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where phone_number = v_prev_from_number
    into v_sending_location_id; 

    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage, estimated_segments)
    values (send_message.to, v_prev_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls, 'prev_mapping', v_estimated_segments)
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

  with
    phones_with_no_commitments as (
      select 0 as commitment, phone_number as from_number
      from sms.phone_numbers
      where sending_location_id = v_sending_location_id
        and not exists ( 
          select 1
          from sms.outbound_messages
          where from_number = sms.phone_numbers.phone_number
        )
    ),
    phones_with_free_fresh_commitments as (
      select count(*) as commitment, from_number
      from sms.outbound_messages
      where created_at > now() - interval '36 hours'
        and sending_location_id = v_sending_location_id
      group by sms.outbound_messages.from_number
      having count(*) < 200
    ),
    ordered_by_full_commitment_counts as (
      (
        select count(*) as commitment, from_number
        from sms.outbound_messages
        where from_number in (
          select from_number
          from phones_with_free_fresh_commitments
        )
        group by sms.outbound_messages.from_number
      )
      union (
        select commitment, from_number from phones_with_no_commitments
      )
      order by commitment
    )
    select from_number
    from ordered_by_full_commitment_counts
    limit 1
    into v_from_number;

  if v_from_number is not null then
    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage, estimated_segments)
    values (send_message.to, v_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls, 'existing_phone_number', v_estimated_segments)
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
    insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage, estimated_segments)
    values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls, 'existing_pending_request', v_estimated_segments)
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

  insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage, estimated_segments)
  values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls, 'new_pending_request', v_estimated_segments)
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

grant execute on function sms.send_message to client;

