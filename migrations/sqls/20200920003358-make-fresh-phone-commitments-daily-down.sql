alter table sms.fresh_phone_commitments drop constraint fresh_phone_commitments_pkey;

alter table sms.fresh_phone_commitments add column truncated_day timestamp;

alter table sms.fresh_phone_commitments add primary key (truncated_day, phone_number);

drop index sms.choose_existing_phone_number_idx;

create index choose_existing_phone_number_idx on sms.fresh_phone_commitments (sending_location_id, truncated_day, commitment DESC) WITH (fillfactor='70');

CREATE OR REPLACE FUNCTION sms.increment_commitment_bucket_if_unique() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
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
$$;


CREATE OR REPLACE FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[]) RETURNS public.phone_number
    LANGUAGE plpgsql VOLATILE
    AS $$
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
$$;

