alter table sms.outbound_messages drop column send_before;

DROP FUNCTION sms.send_message;
CREATE FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code DEFAULT NULL::text) RETURNS sms.outbound_messages
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

  insert into sms.outbound_messages (profile_id, to_number, stage, body, media_urls, contact_zip_code, estimated_segments)
  values (send_message.profile_id, send_message.to, 'processing', body, media_urls, v_contact_zip_code, v_estimated_segments)
  returning *
  into v_result;

  return v_result;
end;
$$;

grant execute on function sms.send_message to client;

