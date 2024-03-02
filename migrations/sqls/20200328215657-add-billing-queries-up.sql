create or replace view billing.past_month_inbound_sms as
  SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(inbound_messages.num_segments) FILTER (WHERE inbound_messages.num_media = 0) AS sms_segments,
    sum(inbound_messages.num_segments) FILTER (WHERE inbound_messages.num_media > 0) AS mms_segments
   FROM sms.inbound_messages
     JOIN sms.sending_locations ON sending_locations.id = inbound_messages.sending_location_id
     JOIN sms.profiles ON profiles.id = sending_locations.profile_id
     JOIN sms.sending_accounts ON sending_accounts.id = profiles.sending_account_id
     JOIN billing.clients ON clients.id = profiles.client_id
  WHERE inbound_messages.received_at >= (date_trunc('month'::text, now()) - '1 mon'::interval)
    AND inbound_messages.received_at < date_trunc('month'::text, now())
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, sending_accounts.service;

create or replace view billing.past_month_lrn_usage as
   WITH client_counts AS (
    SELECT count(DISTINCT past_month_accesses.phone_number) AS lookup_count,
      past_month_accesses.client_id
    FROM lookup.accesses past_month_accesses
    WHERE date_trunc('month'::text, past_month_accesses.accessed_at) = date_trunc('month'::text, now() - '1 mon'::interval)
      AND NOT (
        EXISTS (
          SELECT 1
          FROM lookup.accesses previous_accesses
          WHERE date_trunc('month'::text, previous_accesses.accessed_at) < date_trunc('month'::text, now() - '1 mon'::interval)
            AND previous_accesses.phone_number::text = past_month_accesses.phone_number::text
        )
      )
    GROUP BY past_month_accesses.client_id
  )
 SELECT clients.id AS client_id,
    clients.name AS client_name,
    client_counts.lookup_count
  FROM client_counts
  JOIN billing.clients ON clients.id = client_counts.client_id;

create or replace view billing.past_month_number_count as
  SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(
      CASE
        WHEN phone_numbers.created_at < (date_trunc('month'::text, now()) - '1 mon'::interval) THEN 1::double precision
        ELSE date_part('day'::text, date_trunc('month'::text, now()) - phone_numbers.created_at::timestamp with time zone) / date_part('day'::text, date_trunc('month'::text, now()) - (date_trunc('month'::text, now()) - '1 mon'::interval))
      END
    ) AS number_months
  FROM sms.phone_numbers
  JOIN sms.sending_locations ON sending_locations.id = phone_numbers.sending_location_id
  JOIN sms.profiles ON profiles.id = sending_locations.profile_id
  JOIN sms.sending_accounts ON sending_accounts.id = profiles.sending_account_id
  JOIN billing.clients ON clients.id = profiles.client_id
  WHERE phone_numbers.created_at < date_trunc('month'::text, now())
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, 4 DESC;

create or replace view billing.past_month_outbound_sms as
  SELECT clients.id AS client_id,
    clients.name AS client_name,
    sending_accounts.service,
    sum(outbound_messages.num_segments) FILTER (WHERE outbound_messages.stage = 'sent'::sms.outbound_message_stages AND outbound_messages.num_media = 0) AS sms_segments,
    sum(outbound_messages.num_segments) FILTER (WHERE outbound_messages.stage = 'sent'::sms.outbound_message_stages AND outbound_messages.num_media > 0) AS mms_segments,
    count(1) FILTER (WHERE outbound_messages.stage = 'queued'::sms.outbound_message_stages OR outbound_messages.stage = 'awaiting-number'::sms.outbound_message_stages) AS queued_messages
  FROM sms.outbound_messages
    JOIN sms.sending_locations ON sending_locations.id = outbound_messages.sending_location_id
    JOIN sms.profiles ON profiles.id = sending_locations.profile_id
    JOIN sms.sending_accounts ON sending_accounts.id = profiles.sending_account_id
    JOIN billing.clients ON clients.id = profiles.client_id
  WHERE outbound_messages.created_at >= (date_trunc('month'::text, now()) - '1 mon'::interval)
    AND outbound_messages.created_at < date_trunc('month'::text, now())
  GROUP BY clients.id, clients.name, sending_accounts.service
  ORDER BY clients.name, sending_accounts.service;

create or replace function billing.lrn_usage(client uuid, month timestamptz)
returns table (client_id uuid, period_start timestamptz, period_end timestamptz, lookup_count bigint)
language plpgsql
as $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    lookup.accesses.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    count(distinct lookup.accesses.phone_number) as lookup_count
  from lookup.accesses
  where true
    and lookup.accesses.client_id = lrn_usage.client
    and lookup.accesses.accessed_at >= v_month_start
    and lookup.accesses.accessed_at < v_month_end
    and not exists (
      select 1
      from lookup.accesses as previous_accesses
      where true
        and previous_accesses.client_id = lrn_usage.client
        and previous_accesses.phone_number = lookup.accesses.phone_number
        and previous_accesses.accessed_at < lookup.accesses.accessed_at
    )
  group by 1;
end;
$$;

create or replace function billing.phone_number_usage(client uuid, month timestamptz)
returns table (client_id uuid, period_start timestamptz, period_end timestamptz, service sms.profile_service_option, number_months float)
language plpgsql
as $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
  v_days_in_month int;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;
	select extract(days from v_month_start + '1 month - 1 day'::interval) into v_days_in_month;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(
      extract(day from least(v_month_end, released_at) - greatest(v_month_start, created_at)) / v_days_in_month::float
    ) as number_months  
  from sms.all_phone_numbers
  join sms.sending_locations
    on sms.sending_locations.id = sms.all_phone_numbers.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = phone_number_usage.client
    and sms.all_phone_numbers.created_at < v_month_end
    and (
      sms.all_phone_numbers.released_at is null
      or sms.all_phone_numbers.released_at >= v_month_start
    )
  group by 1, 4
  order by
    number_months desc;
end;
$$;

create or replace function billing.outbound_message_usage(client uuid, month timestamptz)
returns table (
  client_id uuid,
  period_start timestamptz,
  period_end timestamptz,
  service sms.profile_service_option,
  sms_segments bigint,
  mms_segments bigint,
  queued_messages bigint
)
language plpgsql
as $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media = 0) as sms_segments,
    sum(sms.outbound_messages.num_segments) filter (where stage = 'sent' and num_media > 0) as mms_segments,
    count(1) filter (where stage = 'queued' or stage = 'awaiting-number') as queued_messages
  from sms.outbound_messages
  join sms.sending_locations
    on sms.sending_locations.id = sms.outbound_messages.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = client
    and sms.outbound_messages.created_at >= v_month_start
    and sms.outbound_messages.created_at < v_month_end
  group by 1, 4
  order by
    sms_segments desc;
end;
$$;

create or replace function billing.inbound_message_usage(client uuid, month timestamptz)
returns table (
  client_id uuid,
  period_start timestamptz,
  period_end timestamptz,
  service sms.profile_service_option,
  sms_segments bigint,
  mms_segments bigint
)
language plpgsql
as $$
declare
  v_month_start timestamptz;
  v_month_end timestamptz;
begin
  select date_trunc('month', month) into v_month_start;
  select date_trunc('month', month + '1 month'::interval) into v_month_end;

  return query
  select
    sms.profiles.client_id,
    v_month_start as period_start,
    v_month_end as period_end,
    sms.sending_accounts.service,
    sum(num_segments) filter (where num_media = 0) as sms_segments,
    sum(num_segments) filter (where num_media > 0) as mms_segments
  from sms.inbound_messages
  join sms.sending_locations
    on sms.sending_locations.id = sms.inbound_messages.sending_location_id
  join sms.profiles
    on sms.profiles.id = sms.sending_locations.profile_id
  join sms.sending_accounts
    on sms.sending_accounts.id = sms.profiles.sending_account_id
  where true
    and sms.profiles.client_id = client
    and sms.inbound_messages.received_at >= v_month_start
    and sms.inbound_messages.received_at < v_month_end
  group by 1, 4
  order by
    sms_segments desc;
end;
$$;
