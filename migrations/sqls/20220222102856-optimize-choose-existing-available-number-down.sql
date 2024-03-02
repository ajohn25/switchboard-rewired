-- Revert choose_existing_available_number
-- -----------------------------------------

CREATE OR REPLACE FUNCTION sms.choose_existing_available_number(sending_location_id_options uuid[], profile_daily_contact_limit integer default 200, profile_throughput_limit integer default 6) RETURNS public.phone_number
    LANGUAGE plpgsql
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
    )
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  -- Next, find the one least texted not currently overloaded and not cordoned
  with recent_segment_counts as (
    select sum(estimated_segments) as estimated_segments, from_number
    from sms.outbound_messages_routing
    where processed_at > now() - '1 minute'::interval
      and stage <> 'awaiting-number'
      and original_created_at > date_trunc('day', now())
    group by sms.outbound_messages_routing.from_number
  )
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and commitment <= profile_daily_contact_limit
    and phone_number not in (
      select from_number
      from recent_segment_counts
      where estimated_segments >= profile_throughput_limit
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
