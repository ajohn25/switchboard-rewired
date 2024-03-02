alter table sms.outbound_messages alter column sending_location_id drop not null;

-- outside of transaction block - modified in history for new deployments / dev
-- alter type sms.outbound_message_stages add value 'processing';

drop function sms.send_message;

create or replace function sms.send_message (profile_id uuid, "to" phone_number, body text, media_urls url[], contact_zip_code zip_code default null) returns sms.outbound_messages as $$
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

  insert into sms.outbound_messages (profile_id, to_number, stage, body, media_urls, contact_zip_code, estimated_segments)
  values (send_message.profile_id, send_message.to, 'processing', body, media_urls, v_contact_zip_code, v_estimated_segments)
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

grant execute on function sms.send_message to client;

create or replace function sms.process_message (message sms.outbound_messages) returns sms.outbound_messages as $$
declare
  v_sending_location_id uuid;
  v_prev_from_number phone_number;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number
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
    )
  order by created_at desc
  limit 1
  into v_prev_from_number;

  if v_prev_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where phone_number = v_prev_from_number
    into v_sending_location_id; 

    update sms.outbound_messages
    set from_number = v_prev_from_number,
        stage = 'queued',
        sending_location_id = v_sending_location_id,
        decision_stage = 'prev_mapping'
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
      select count(distinct to_number) as commitment, from_number
      from sms.outbound_messages
      where created_at > now() - interval '12 hours'
        and exists (
          select 1
          from sms.phone_numbers
          where sms.phone_numbers.sending_location_id = v_sending_location_id
            and sms.phone_numbers.phone_number = sms.outbound_messages.from_number
        )
      group by sms.outbound_messages.from_number
      having count(distinct to_number) < 200
    ),
    phones_with_overloaded_queues as (
      select sum(estimated_segments) as commitment, from_number
      from sms.outbound_messages
      where created_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
        and from_number in (
          select from_number from phones_with_free_fresh_commitments
        )
      group by sms.outbound_messages.from_number
      having sum(estimated_segments) > 6
    )
    select from_number
    from ( select * from phones_with_free_fresh_commitments union select * from phones_with_no_commitments ) as all_phones
    where from_number not in (
      select from_number
      from phones_with_overloaded_queues
    )
    order by commitment
    limit 1
    into v_from_number;

  if v_from_number is not null then
    update sms.outbound_messages
    set from_number = v_from_number,
        stage = 'queued',
        decision_stage = 'existing_phone_number',
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
        decision_stage = 'existing_pending_request'
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
      decision_stage = 'new_pending_request'
  where id = message.id
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

create trigger _500_process_outbound_message
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.stage = 'processing')
  execute procedure trigger_job('process-message');

create trigger _500_send_message_after_process
  after update
  on sms.outbound_messages
  for each row
  when (NEW.stage = 'queued' and OLD.stage = 'processing')
  execute procedure sms.trigger_send_message();
