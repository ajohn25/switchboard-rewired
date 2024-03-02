-- Revert pending_number_request_capacity
-- ----------------------------------------------

drop index sms.phone_number_requests_id_idx;

create or replace view sms.pending_number_request_capacity as
  select
      pending_number_request_id
    , count(*) as commitment_count
  from sms.outbound_messages_awaiting_from_number
  group by 1
  union
  select
      id as pending_number_request_id
    , 0 as commitment_count
  from sms.phone_number_requests
  where true
    and id not in ( select pending_number_request_id from sms.outbound_messages_awaiting_from_number );
