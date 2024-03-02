create or replace view sms.pending_number_request_capacity as
  select id as pending_number_request_id, coalesce(commitment_counts.commitment_count, 0) as commitment_count
  from sms.phone_number_requests
  left join (
    select count(*) as commitment_count, pending_number_request_id
    from sms.outbound_messages
    where stage = 'awaiting-number'::sms.outbound_message_stages
    group by pending_number_request_id
  ) as commitment_counts on sms.phone_number_requests.id = pending_number_request_id
  where fulfilled_at is null;

comment on view sms.pending_number_request_capacity is E'@omit';

alter table sms.phone_number_requests drop column commitment_count;

drop trigger _500_increment_pending_request_commitment_after_update on sms.outbound_messages;
drop trigger _500_increment_pending_request_commitment_after_insert on sms.outbound_messages;

drop function sms.tg__outbound_messages__increment_pending_request_commitment;
drop function sms.backfill_pending_request_commitment_counts();

create index outbound_messages_request_fulfillment_idx on sms.outbound_messages (pending_number_request_id) where stage = 'awaiting-number';
