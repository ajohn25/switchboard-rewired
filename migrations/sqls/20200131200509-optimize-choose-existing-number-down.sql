-- Old increment trigger
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
    insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment)
    values (NEW.from_number, date_trunc('day', current_timestamp), 1)
    on conflict (truncated_day, phone_number)
    do update
    set commitment = sms.fresh_phone_commitments.commitment + 1;
  end if;

  return NEW;
end;
$$ language plpgsql volatile strict;

-- Old choose_existing_number
create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns phone_number as $$
  with phones_with_no_commitments as (
    select 0 as commitment, phone_number as from_number
    from sms.phone_numbers
    where sending_location_id = ANY(sending_location_id_options)
      and phone_number not in (
        select phone_number
        from sms.fresh_phone_commitments
        where truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
      )
  ),
  phones_with_free_fresh_commitments as (
    select commitment, phone_number as from_number
    from sms.fresh_phone_commitments
    where commitment <= 200
      and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
      and phone_number in (
        select phone_number
        from sms.phone_numbers
        where sms.phone_numbers.sending_location_id = ANY(sending_location_id_options)
      )
  ),
  phones_with_overloaded_queues as (
    select sum(estimated_segments) as commitment, from_number
    from sms.outbound_messages
    where processed_at > now() - interval '1 minute'
      and stage <> 'awaiting-number'
      and from_number in (
        select from_number from phones_with_free_fresh_commitments
      )
    group by sms.outbound_messages.from_number
    having sum(estimated_segments) > 6
  )
  select from_number
  from ( select * from phones_with_free_fresh_commitments union select * from phones_with_no_commitments ) as all_phones
  where from_number not in (
    select from_number
    from phones_with_overloaded_queues
  )
  order by commitment
  limit 1
$$ language sql;

-- Undo DDL
alter table sms.fresh_phone_commitments drop column sending_location_id;

-- Undo index change
drop index sms.outbound_messages_phone_number_overloaded_idx;
create index outbound_messages_phone_number_overloaded_idx on sms.outbound_messages (from_number, processed_at desc);

