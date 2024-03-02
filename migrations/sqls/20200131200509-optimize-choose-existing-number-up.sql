-- Development
alter table sms.fresh_phone_commitments add column sending_location_id uuid references sms.sending_locations (id) not null;
create index choose_existing_phone_number_idx on sms.fresh_phone_commitments (sending_location_id, truncated_day, commitment asc);

drop index sms.outbound_messages_phone_number_overloaded_idx;
create index outbound_messages_phone_number_overloaded_idx on sms.outbound_messages (processed_at desc, from_number) include (estimated_segments) where stage <> 'awaiting-number';

/* Production
alter table sms.fresh_phone_commitments add column sending_location_id uuid references sms.sending_locations (id);
alter table sms.fresh_phone_commitments alter column sending_location_id set not null;

update sms.fresh_phone_commitments
set sending_location_id = sms.all_phone_numbers.sending_location_id
from sms.all_phone_numbers
where sms.fresh_phone_commitments.phone_number = sms.all_phone_numbers.phone_number
  and sms.fresh_phone_commitments.sending_location_id is null;

create index concurrently choose_existing_phone_number_idx on sms.fresh_phone_commitments (sending_location_id, truncated_day, commitment desc);

drop index concurrently sms.outbound_messages_phone_number_overloaded_idx;
create index concurrently sms.outbound_messages_phone_number_overloaded_idx on sms.outbound_messages (processed_at desc, from_number) include (estimated_segments) where stage <> 'awaiting-number';
*/

-- Add sending_location_id to commitment bucket insert
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

create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns public.phone_number as $$
declare
  v_phone_number phone_number;
begin
  -- First, check for numbers not texted today
  select phone_number
  from sms.phone_numbers
  where sending_location_id = ANY(sending_location_id_options)
    and not exists (
      select 1
      from sms.fresh_phone_commitments
      where sms.fresh_phone_commitments.phone_number = sms.phone_numbers.phone_number
        and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    )
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  -- Next, find the one least texted not currently overloaded
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    and commitment <= 200
    and phone_number not in (
      select from_number
      from sms.outbound_messages
      where processed_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
      group by sms.outbound_messages.from_number
      having sum(estimated_segments) > 6
    )
  order by commitment
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$ language plpgsql stable;
