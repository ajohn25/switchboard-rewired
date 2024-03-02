-- Optimize pending_number_request_capacity
-- ----------------------------------------------

create or replace view sms.pending_number_request_capacity as
  select
      pending_number_request_id
    , count(*) as commitment_count
  from sms.outbound_messages_awaiting_from_number
  group by 1
  union
  select
      phone_number_requests.id as pending_number_request_id
    , 0 as commitment_count
  from sms.phone_number_requests
  left join sms.outbound_messages_awaiting_from_number on phone_number_requests.id = outbound_messages_awaiting_from_number.pending_number_request_id
  where true
    and outbound_messages_awaiting_from_number.pending_number_request_id is null
    and fulfilled_at is null;
