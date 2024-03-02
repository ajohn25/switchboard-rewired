alter table sms.phone_number_requests add column commitment_count bigint default 0;

create or replace view sms.pending_number_request_capacity as
  select
    id as pending_number_request_id,
    commitment_count as commitment_count
  from sms.phone_number_requests
  where fulfilled_at is null;

comment on view sms.pending_number_request_capacity is E'@omit';

create or replace function sms.tg__outbound_messages__increment_pending_request_commitment() returns trigger as $$
begin
  update sms.phone_number_requests
  set commitment_count = commitment_count + 1
  where id = NEW.pending_number_request_id;

  return NEW;
end;
$$ language plpgsql strict;

create trigger _500_increment_pending_request_commitment_after_update
  after update
  on sms.outbound_messages
  for each row
  when (NEW.pending_number_request_id is not null and OLD.pending_number_request_id is null)
  execute procedure sms.tg__outbound_messages__increment_pending_request_commitment();

create trigger _500_increment_pending_request_commitment_after_insert
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.pending_number_request_id is not null)
  execute procedure sms.tg__outbound_messages__increment_pending_request_commitment();

create or replace function sms.backfill_pending_request_commitment_counts() returns void as $$
  with pending_number_commitment_counts as (
    select id as pending_number_request_id, coalesce(commitment_counts.commitment_count, 0) as commitment_count
    from sms.phone_number_requests
    left join (
      select count(*) as commitment_count, pending_number_request_id
      from sms.outbound_messages
      where stage = 'awaiting-number'::sms.outbound_message_stages
      group by pending_number_request_id
    ) as commitment_counts on sms.phone_number_requests.id = pending_number_request_id
    where fulfilled_at is null
  )
  update sms.phone_number_requests
  set commitment_count = pending_number_commitment_counts.commitment_count
  from pending_number_commitment_counts
  where pending_number_commitment_counts.pending_number_request_id = sms.phone_number_requests.id
$$ language sql;

-- In production, run:
-- drop index concurrently sms.outbound_messages_request_fulfillment_idx;
drop index sms.outbound_messages_request_fulfillment_idx;
