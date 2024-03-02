-- New column and index
alter table sms.all_phone_numbers add column cordoned_at timestamp;

create index phone_number_is_cordoned_idx on sms.all_phone_numbers (cordoned_at);

drop view billing.past_month_number_count; -- TODO - include decomissioning in number pro-rating
drop view sms.phone_numbers;

create view sms.phone_numbers as
  select phone_number, created_at, sending_location_id, cordoned_at
  from sms.all_phone_numbers
  where released_at is null;

comment on view sms.phone_numbers is '@omit';

create or replace view billing.past_month_number_count as
  SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(
      CASE
        WHEN sms.all_phone_numbers.created_at < (date_trunc('month'::text, now()) - '1 mon'::interval) THEN 1::double precision
        ELSE date_part('day'::text, date_trunc('month'::text, now()) - sms.all_phone_numbers.created_at::timestamp with time zone) / date_part('day'::text, date_trunc('month'::text, now()) - (date_trunc('month'::text, now()) - '1 mon'::interval))
      END
    ) AS number_months
  FROM sms.all_phone_numbers
  JOIN sms.sending_locations ON sending_locations.id = sms.all_phone_numbers.sending_location_id
  JOIN sms.profiles ON profiles.id = sending_locations.profile_id
  JOIN sms.sending_accounts ON sending_accounts.id = profiles.sending_account_id
  JOIN billing.clients ON clients.id = profiles.client_id
  WHERE sms.all_phone_numbers.created_at < date_trunc('month'::text, now())
    AND sms.all_phone_numbers.sold_at is null
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, 4 DESC;

-- New process message 
create or replace function sms.process_message (message sms.outbound_messages) returns sms.outbound_messages as $$
declare
  v_sending_location_id uuid;
  v_prev_from_number phone_number;
  v_from_number phone_number;
  v_pending_number_request_id uuid;
  v_area_code area_code;
  v_estimated_segments integer;
  v_result sms.outbound_messages;
begin
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number
  from sms.outbound_messages
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages.from_number
        and (
          sms.phone_numbers.cordoned_at is null
          or
          sms.phone_numbers.cordoned_at > now() - interval '3 days'
        )
    )
  order by created_at desc
  limit 1
  into v_prev_from_number;

  if v_prev_from_number is not null then
    select sending_location_id
    from sms.phone_numbers
    where phone_number = v_prev_from_number
    into v_sending_location_id; 

    update sms.outbound_messages
    set from_number = v_prev_from_number,
        stage = 'queued',
        sending_location_id = v_sending_location_id,
        decision_stage = 'prev_mapping',
        processed_at = now()
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it's a number we haven't seen before
  select sms.choose_sending_location_for_contact(message.contact_zip_code, message.profile_id)
  into v_sending_location_id;

  if v_sending_location_id is null then
    raise 'Must create a sending location before sending messages';
  end if;

  select sms.choose_existing_available_number(ARRAY[v_sending_location_id])
  into v_from_number;

  if v_from_number is not null then
    update sms.outbound_messages
    set from_number = v_from_number,
        stage = 'queued',
        decision_stage = 'existing_phone_number',
        processed_at = now(),
        sending_location_id = v_sending_location_id
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;

  -- If we're here, it means we need to buy a new number
  -- this could be because no numbers exist, or all are at or above capacity

  -- try to map it to existing pending number request
  select pending_number_request_id
  from sms.pending_number_request_capacity
  where commitment_count < 200
    and sms.pending_Number_request_capacity.pending_number_request_id in (
      select id
      from sms.phone_number_requests
      where sms.phone_number_requests.sending_location_id = v_sending_location_id
        and sms.phone_number_requests.fulfilled_at is null
    )
  limit 1
  into v_pending_number_request_id;

  if v_pending_number_request_id is not null then
    update sms.outbound_messages
    set pending_number_request_id = v_pending_number_request_id,
        stage = 'awaiting-number',
        sending_location_id = v_sending_location_id,
        decision_stage = 'existing_pending_request',
        processed_at = now()
    where id = message.id
    returning *
    into v_result;

    return v_result;
  end if;
 
  -- need to create phone_number_request - gotta pick an area code
  select sms.choose_area_code_for_sending_location(v_sending_location_id) into v_area_code;

  insert into sms.phone_number_requests (sending_location_id, area_code)
  values (v_sending_location_id, v_area_code)
  returning id
  into v_pending_number_request_id;

  update sms.outbound_messages
  set pending_number_request_id = v_pending_number_request_id,
      stage = 'awaiting-number',
      sending_location_id = v_sending_location_id,
      decision_stage = 'new_pending_request',
      processed_at = now()
  where id = message.id
  returning *
  into v_result;

  return v_result;
end;
$$ language plpgsql security definer;

-- New choose_existing_available_number shouldn't choose cordoned numbers
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
  limit 1
  into v_phone_number;

  if v_phone_number is not null then
    return v_phone_number;
  end if;

  return null;
end;
$$ language plpgsql stable;

-- Utility function for selling numbers that have been cordoned after n days
create or replace function sms.sell_cordoned_numbers(n_days integer) returns bigint as $$
  with sell_result as (
    update sms.all_phone_numbers
    set sold_at = now()
    where sold_at is null
      and cordoned_at > now() - (interval '1 days' * n_days)
    returning 1
  )
  select count(*)
  from sell_result
$$ language sql volatile strict;
