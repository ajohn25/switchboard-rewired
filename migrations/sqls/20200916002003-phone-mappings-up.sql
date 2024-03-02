create table sms.daily_phone_mappings (
  sending_location_id uuid not null references sms.sending_locations(id) on delete cascade,
  from_number phone_number not null,
  to_number phone_number not null,
  truncated_day timestamp not null,
  primary key (sending_location_id, from_number, to_number, truncated_day)
);

create or replace function sms.add_phone_mapping() returns trigger as $$
begin
  insert into sms.daily_phone_mappings (sending_location_id, from_number, to_number, truncated_day)
  values (NEW.sending_location_id, NEW.from_number, NEW.to_number, date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu'))
  on conflict (sending_location_id, from_number, to_number, truncated_day)
  do nothing;

  return NEW;
end;
$$ language plpgsql volatile strict;

create trigger _500_add_phone_mapping_after_update
  after update
  on sms.outbound_messages
  for each row
  when (OLD.from_number is null and NEW.from_number is not null)
  execute procedure sms.add_phone_mapping();

create trigger _500_add_phone_mapping_after_insert
  after insert
  on sms.outbound_messages
  for each row
  when (NEW.from_number is not null)
  execute procedure sms.add_phone_mapping();

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
      from sms.daily_phone_mappings
      where sms.daily_phone_mappings.from_number = sms.phone_numbers.phone_number
        and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
        and sending_location_id = ANY(sending_location_id_options)
    )
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  -- Next, find the one least texted not currently overloaded and not cordoned
  select from_number
  from sms.daily_phone_mappings
  where sending_location_id = ANY(sending_location_id_options)
    and truncated_day = date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
    and from_number not in (
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
      where sms.phone_numbers.phone_number = sms.daily_phone_mappings.from_number
        and not (cordoned_at is null)
    )
  group by from_number
  having count(*) <= 200
  order by count(*) asc
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$ language plpgsql stable strict;

drop trigger _500_increment_commitment_bucket_after_update on sms.outbound_messages;
drop trigger _500_increment_commitment_bucket_after_insert on sms.outbound_messages;
drop function sms.increment_commitment_bucket_if_unique;

create or replace function sms.backfill_phone_mappings() returns void as $$
  insert into sms.daily_phone_mappings (sending_location_id, from_number, to_number, truncated_day)
  select
    sending_location_id,
    from_number,
    to_number,
    date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
  from sms.outbound_messages
  where processed_at > date_trunc('day', current_timestamp at time zone 'Pacific/Honolulu')
  on conflict do nothing;
$$ language sql volatile;

