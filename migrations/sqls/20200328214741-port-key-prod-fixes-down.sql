create or replace function sms.estimate_segments (body text) returns integer as $$
  select char_length(body) / 160
$$ language sql immutable;

create or replace function sms.increment_commitment_bucket_if_unique() returns trigger as $$
declare
  v_already_recorded boolean;
begin
  select exists (
    select 1
    from sms.outbound_messages
    where sms.outbound_messages.from_number = NEW.from_number
      and sms.outbound_messages.to_number = NEW.to_number
      and sms.outbound_messages.processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu') 
      and sms.outbound_messages.processed_at < NEW.processed_at
  )
  into v_already_recorded;

  if not v_already_recorded then
    insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment, sending_location_id)
    values (NEW.from_number, date_trunc('day', current_timestamp), 1, NEW.sending_location_id)
    on conflict (truncated_day, phone_number)
    do update
    set commitment = sms.fresh_phone_commitments.commitment + 1;
  end if;

  return NEW;
end;
$$ language plpgsql volatile strict;

