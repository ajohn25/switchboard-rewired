-- Use custom exception for inbound message that cannot be matched to active sending TN

CREATE OR REPLACE FUNCTION sms.tg__inbound_messages__attach_to_sending_location() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
  v_sending_location_id uuid;
begin
  select sending_location_id
  from sms.phone_numbers
  where phone_number = NEW.to_number
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise exception 'Could not match % to a known sending location', NEW.to_number using ERRCODE = 'SI000';
  end if;

  NEW.sending_location_id = v_sending_location_id;
  return NEW;
end;
$$;
