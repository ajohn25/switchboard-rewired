drop view sms.phone_number_capacity;

create index phone_number_sending_location_id_idx on sms.phone_numbers (sending_location_id);
create index phone_number_capacity_idx on sms.outbound_messages (from_number, created_at desc);

drop function sms.send_message;

create or replace function sms.send_message (profile_id uuid, "to" phone_number, body text, media_urls url[], contact_zip_code zip_code default null) returns sms.outbound_messages as $$
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


  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select *
  from sms.outbound_messages
  where to_number = send_message.to
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = v_profile_id
    )
  order by created_at desc
  limit 1
  into v_previous_sent_message;

  if v_previous_sent_message is not null then
    select from_number from v_previous_sent_message into v_from_number;
    select sending_location_id from v_previous_sent_message into v_sending_location_id; 

    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage)
    values (send_message.to, v_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls, 'prev_mapping')
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
    phones_with_free_fresh_commitments as (
      select count(*), from_number
      from sms.outbound_messages
      where created_at > now() - interval '36 hours'
        and sending_location_id = v_sending_location_id
      group by sms.outbound_messages.from_number
      having count(*) < 200
    ),
    ordered_by_full_commitment_counts as (
      select count(*), from_number
      from sms.outbound_messages
      where from_number in (
        select from_number
        from phones_with_free_fresh_commitments
      )
      group by sms.outbound_messages.from_number
      order by count(*)
    )
    select from_number
    from ordered_by_full_commitment_counts
    limit 1
    into v_from_number;

  if v_from_number is not null then
    insert into sms.outbound_messages (to_number, from_number, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage)
    values (send_message.to, v_from_number, 'queued', v_sending_location_id, v_contact_zip_code, body, media_urls, 'existing_phone_number')
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
    insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage)
    values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls, 'existing_pending_request')
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

  insert into sms.outbound_messages (to_number, pending_number_request_id, stage, sending_location_id, contact_zip_code, body, media_urls, decision_stage)
  values (send_message.to, v_pending_number_request_id, 'awaiting-number', v_sending_location_id, v_contact_zip_code, body, media_urls, 'new_pending_request')
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

grant execute on function sms.send_message to client;
