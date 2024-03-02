CREATE TRIGGER _500_increment_commitment_bucket_after_insert 
	AFTER INSERT ON sms.outbound_messages_routing 
	FOR EACH ROW WHEN (((new.from_number IS NOT NULL) AND (new.first_from_to_pair_of_day = true)))
	EXECUTE FUNCTION sms.increment_commitment_bucket_if_unique();

CREATE TRIGGER _500_increment_commitment_bucket_after_update 
	AFTER UPDATE ON sms.outbound_messages_routing 
	FOR EACH ROW WHEN (((old.from_number IS NULL) AND (new.from_number IS NOT NULL) AND (new.first_from_to_pair_of_day = true))) 
	EXECUTE FUNCTION sms.increment_commitment_bucket_if_unique();

CREATE FUNCTION sms.process_grey_route_message(message sms.outbound_messages) RETURNS json
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
  v_result record;
begin
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
      sending_location_id,
      profile_id
    )
    values (
      message.id,
      message.created_at,
      v_from_number,
      message.to_number,
      'queued',
      'existing_phone_number',
      now(),
      v_sending_location_id,
      message.profile_id
    )
    returning *
    into v_result;

    return row_to_json(v_result);
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
    insert into sms.outbound_messages_awaiting_from_number (
      id,
      original_created_at,
      to_number,
      pending_number_request_id,
      sending_location_id,
      decision_stage,
      processed_at,
      estimated_segments,
      profile_id
    )
    values (
      message.id,
      message.created_at,
      message.to_number,
      v_pending_number_request_id,
      v_sending_location_id,
      'existing_pending_request',
      now(),
      message.estimated_segments,
      message.profile_id
    )
    returning *
    into v_result;

    return row_to_json(v_result);
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

  insert into sms.outbound_messages_awaiting_from_number (
    id,
    original_created_at,
    to_number,
    pending_number_request_id,
    sending_location_id,
    decision_stage,
    processed_at,
    estimated_segments,
    profile_id
  )
  values (
    message.id,
    message.created_at,
    message.to_number,
    v_pending_number_request_id,
    v_sending_location_id,
    'new_pending_request',
    now(),
    message.estimated_segments,
    message.profile_id
  )
  returning *
  into v_result;

  return row_to_json(v_result);
end;
$$;
