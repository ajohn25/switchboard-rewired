-- Update sms.tg__phone_number_requests__fulfill()
-- -----------------------------------------------

create or replace function sms.tg__phone_number_requests__fulfill() returns trigger
  language plpgsql
  as $$
begin
  insert into sms.phone_numbers (sending_location_id, phone_number)
  values (NEW.sending_location_id, NEW.phone_number);

  with interval_waits as (
    select
      id,
      to_number,
      sum(estimated_segments) over (partition by 1 order by created_at) as nth_segment
    from (
      select id, to_number, estimated_segments, created_at
      from sms.outbound_messages_routing
      where pending_number_request_id = NEW.id
        and sms.outbound_messages_routing.stage = 'awaiting-number'::sms.outbound_message_stages
    ) all_messages
  )
  update sms.outbound_messages_routing
  set from_number = NEW.phone_number,
      stage = 'queued'::sms.outbound_message_stages,
      send_after = now() + (interval_waits.nth_segment * interval '10 seconds')
  from interval_waits
  where
    -- join on indexed to_number
    interval_waits.to_number = sms.outbound_messages_routing.to_number
    -- then filter by un-indexed sms.outbound_messages_routing.id
    and interval_waits.id = sms.outbound_messages_routing.id;

  return NEW;
end;
$$;
