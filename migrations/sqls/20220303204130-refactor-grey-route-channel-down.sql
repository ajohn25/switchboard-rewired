-- Revert send_message
-- ------------------------------------

CREATE OR REPLACE FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code DEFAULT NULL::text, send_before timestamp without time zone DEFAULT NULL::timestamp without time zone) RETURNS sms.outbound_messages
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

  insert into sms.outbound_messages (profile_id, created_at, to_number, stage, body, media_urls, contact_zip_code, estimated_segments, send_before)
  values (send_message.profile_id, date_trunc('second', now()), send_message.to, 'processing', body, media_urls, v_contact_zip_code, v_estimated_segments, send_message.send_before)
  returning *
  into v_result;

  return v_result;
end;
$$;


ALTER FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) OWNER TO postgres;

GRANT ALL ON FUNCTION sms.send_message(profile_id uuid, "to" public.phone_number, body text, media_urls public.url[], contact_zip_code public.zip_code, send_before timestamp without time zone) TO client;


-- Revert outbound message trigger
-- ------------------------------------

drop trigger _500_process_outbound_message on sms.outbound_messages;
create trigger _500_process_outbound_message
  after insert
  on sms.outbound_messages
  for each row
  when (new.stage = 'processing'::sms.outbound_message_stages)
  execute function trigger_job('process-message');

drop function sms.tg__trigger_process_message;


-- Rename process_message
-- ------------------------------------

alter function sms.process_grey_route_message rename to process_message;


-- Prevent updating sending location profile
-- -----------------------------------------

drop trigger _200_prevent_update_profile on sms.sending_locations;

drop function sms.tg__prevent_update_sending_location_profile();


-- Revert sync grey-route provisioned status
-- -----------------------------------------

drop trigger _700_sync_profile_provisioned_after_update on sms.sending_locations;
drop trigger _700_sync_profile_provisioned on sms.sending_locations;
drop function sms.tg__sync_profile_provisioned();


-- Revert Profile column changes
-- ------------------------------------

alter table sms.profiles
  drop column active,
  drop column disabled,
  drop column provisioned,
  drop column channel;

drop type sms.traffic_channel;
