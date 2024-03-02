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
        'forward-delivery-report',
        payload => row_to_json(payloads),
        queue_name => null,
        priority => 100,
        max_attempts => 6,
        run_at => now() + random() * '1 minute'::interval
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
