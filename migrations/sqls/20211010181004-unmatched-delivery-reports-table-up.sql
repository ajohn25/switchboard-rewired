create table sms.unmatched_delivery_reports (
  message_service_id text not null,
  event_type sms.delivery_report_event not null,
  generated_at timestamp not null,
  created_at timestamp not null default now(),
  service text not null,
  validated boolean not null,
  error_codes text[],
  extra json
);

comment on table sms.unmatched_delivery_reports is E'@omit';

create index on sms.unmatched_delivery_reports (message_service_id);

-- indexes on message_service_id no longer needed
drop index sms.awaiting_resolution_idx; 
drop index sms.delivery_report_service_id_idx;


-- In order to use `is_from_service` as a indicator of what stage
-- in the evolution of this table we're at, we need it to have a default of `true`
-- going forward that isn't backfilled (since we can't backfill it accurately anyways)
-- separating the below into 2 statements means that the default won't be applied to old
-- rows (which will have a default of null), only new ones
alter table sms.delivery_reports add column is_from_service boolean;
alter table sms.delivery_reports alter column is_from_service set default true;

DROP TRIGGER _500_foward_delivery_report on sms.delivery_reports;

CREATE TRIGGER _500_foward_delivery_report
  AFTER INSERT ON sms.delivery_reports 
  FOR EACH ROW 
  WHEN (NEW.is_from_service is false) 
  EXECUTE FUNCTION public.trigger_forward_delivery_report_with_profile_info();

-- from now on (the time when the migration is run), message_id is required
alter table sms.delivery_reports 
  add constraint message_id_required_after_dedicated_unmatched_table
  check (message_id is not null or is_from_service is null);

CREATE OR REPLACE FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval, fire_date timestamp without time zone DEFAULT now(), send_delay_window interval DEFAULT '1 day'::interval) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$ 
  with
    matched as (
      select 
        dr.*, 
        telco.id as message_id, 
        telco.original_created_at as original_created_at,
        telco.profile_id as profile_id,
        (
          coalesce(dr.extra, '{}'::json)::jsonb || json_build_object(
            'num_segments', telco.num_segments,
            'num_media', telco.num_media
          )::jsonb
        )::json as combined_extra
      from sms.unmatched_delivery_reports dr
      join sms.outbound_messages_telco telco on telco.service_id = dr.message_service_id
      where telco.original_created_at > fire_date - send_delay_window
    ),
    do_delete as (
      delete from sms.unmatched_delivery_reports
      where message_service_id in ( select message_service_id from matched )
      returning 1
    ),
    do_insert as (
      insert into sms.delivery_reports (
        message_id, message_service_id, event_type, generated_at,
        created_at, service, validated, error_codes, extra 
      )
      select 
        message_id, message_service_id, event_type, generated_at,
        created_at, service, validated, error_codes, extra 
      from matched
      returning 1
    ),
    payloads as (
      select
        matched.message_service_id,
        matched.message_id,
        matched.event_type,
        matched.generated_at,
        matched.created_at,
        matched.service,
        matched.validated,
        matched.error_codes,
        matched.original_created_at,
        matched.profile_id as profile_id,
        clients.access_token as encrypted_client_access_token,
        profiles.message_status_webhook_url,
        profiles.reply_webhook_url,
        matched.combined_extra as extra
      from matched
      join sms.profiles as profiles on profiles.id = matched.profile_id
      join billing.clients as clients on clients.id = profiles.client_id
    ),
    job_insert_result as (
      select graphile_worker.add_job(
        identifier => 'forward-delivery-report',
        payload => row_to_json(payloads),
        priority => 100,
        max_attempts => 6,
        queue_name => null
      )
      from payloads
    )
  -- there is no meaning or importance to doing least here. these two counts will be the same
  -- we just need to select from both CTEs to guarantee they get executed
  select least(
    ( select count(*) from do_delete ),
    ( select count(*) from do_insert ),
    ( select count(*) from job_insert_result )
  )
$$;

CREATE OR REPLACE FUNCTION public.trigger_forward_delivery_report_with_profile_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
  v_profile_id uuid;
  v_profile_json json;
begin
  select row_to_json(NEW) into v_job;

  select profile_id
  from sms.outbound_messages
  where sms.outbound_messages.id = NEW.message_id
    and sms.outbound_messages.created_at > 'now'::timestamp - interval '1 day'
  into v_profile_id;

  select row_to_json(relevant_profile_fields)
  from (
    select
      profiles.id as profile_id,
      clients.access_token as encrypted_client_access_token,
      profiles.message_status_webhook_url,
      profiles.reply_webhook_url
    from sms.profiles 
    join billing.clients as clients on clients.id = profiles.client_id
    where sms.profiles.id = v_profile_id
  ) relevant_profile_fields
  into v_profile_json;

  select v_job::jsonb || v_profile_json::jsonb into v_job;
  perform graphile_worker.add_job('forward-delivery-report', v_job);
  return NEW;
end;
$$;
