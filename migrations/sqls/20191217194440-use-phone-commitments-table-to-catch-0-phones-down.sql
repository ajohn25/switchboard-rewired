create or replace function sms.choose_existing_available_number(sending_location_id_options uuid[]) returns phone_number as $$
  with phones_with_no_commitments as (
    select 0 as commitment, phone_number as from_number
    from sms.phone_numbers
    where sending_location_id = ANY(sending_location_id_options)
      and not exists (
        select 1
        from sms.outbound_messages
        where from_number = sms.phone_numbers.phone_number
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
