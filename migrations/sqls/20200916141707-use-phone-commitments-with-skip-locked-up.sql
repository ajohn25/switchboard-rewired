alter table sms.fresh_phone_commitments drop constraint fresh_phone_commitments_sending_location_id_fkey;

alter table sms.fresh_phone_commitments add constraint fresh_phone_commitments_sending_location_id_fkey
  foreign key (sending_location_id) references sms.sending_locations (id) on delete cascade;

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
    values (NEW.from_number, date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu'), 1, NEW.sending_location_id)
    on conflict (truncated_day, phone_number)
    do update
    set commitment = sms.fresh_phone_commitments.commitment + 1;
  end if;

  return NEW;
end;
$$ language plpgsql volatile strict;

create trigger _500_increment_commitment_bucket_after_update
  after update
  on sms.outbound_messages
  for each row
  when (OLD.from_number is null and NEW.from_number is not null)
  execute procedure sms.increment_commitment_bucket_if_unique();

create trigger _500_increment_commitment_bucket_after_insert
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.from_number is not null)
  execute procedure sms.increment_commitment_bucket_if_unique();

create or replace function sms.backfill_commitment_buckets() returns void as $$
  with values_to_write as (
    select
      from_number,
      date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu') as truncated_day,
      count(distinct to_number) as commitment,
      sending_location_id
    from sms.outbound_messages
    where processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
          -- can safely limit created_at since only those are relevant buckets
      and processed_at is not null
      and from_number is not null
      and stage <> 'awaiting-number'
    group by 1, 2, 4
  )
  insert into sms.fresh_phone_commitments (phone_number, truncated_day, commitment, sending_location_id)
  select from_number as phone_number, truncated_day, commitment, sending_location_id
  from values_to_write
  on conflict (truncated_day, phone_number)
  do update
  set commitment = excluded.commitment
$$ language sql;

create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns public.phone_number as $$
declare
  v_phone_number phone_number;
begin
  -- First, check for numbers not texted today
  select phone_number
  from sms.phone_numbers
  where sending_location_id = ANY(sending_location_id_options)
    and cordoned_at is null
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

  -- Next, find the one least texted not currently overloaded and not cordoned
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
    -- Check that this phone number isn't cordoned
    and not exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.phone_number = sms.fresh_phone_commitments.phone_number
        and not (cordoned_at is null)
    )
  order by commitment
  for update skip locked
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$ language plpgsql volatile;

drop trigger _500_add_phone_mapping_after_update on sms.outbound_messages;
drop trigger _500_add_phone_mapping_after_insert on sms.outbound_messages;

drop function sms.add_phone_mapping;

drop function sms.backfill_phone_mappings();

drop table sms.daily_phone_mappings;

