CREATE OR REPLACE FUNCTION sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval, fire_date timestamp without time zone DEFAULT now(), send_delay_window interval DEFAULT '1 day'::interval) RETURNS bigint
    LANGUAGE sql STRICT
    AS $$ 
with update_result as (
  update sms.delivery_reports
  set message_id = (
    select id
    from sms.outbound_messages_telco
    where sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
      and sms.outbound_messages_telco.service_id = sms.delivery_reports.message_service_id
  )
  where sms.delivery_reports.message_id is null
    and sms.delivery_reports.created_at >= fire_date - as_far_back_as
    and sms.delivery_reports.created_at <= fire_date - as_recent_as
  returning
    sms.delivery_reports.*
),
payloads as (
  select
    update_result.message_service_id,
    update_result.message_id,
    update_result.event_type,
    update_result.generated_at,
    update_result.created_at,
    update_result.service,
    update_result.validated,
    update_result.error_codes,
    sms.outbound_messages_telco.original_created_at,
    sms.outbound_messages_telco.profile_id as profile_id,
    clients.access_token as encrypted_client_access_token,
    profiles.message_status_webhook_url,
    profiles.reply_webhook_url,
    (
      coalesce(update_result.extra, '{}'::json)::jsonb || json_build_object(
        'num_segments', sms.outbound_messages_telco.num_segments,
        'num_media', sms.outbound_messages_telco.num_media
      )::jsonb
    )::json as extra
  from update_result
  join sms.outbound_messages_telco
    on update_result.message_id = sms.outbound_messages_telco.id
  join sms.profiles as profiles on profiles.id = sms.outbound_messages_telco.profile_id
  join billing.clients as clients on clients.id = profiles.client_id
  where sms.outbound_messages_telco.original_created_at > fire_date - send_delay_window
),
job_insert_result as (
  select graphile_worker.add_job(
    identifier => 'forward-delivery-report',
    payload => row_to_json(payloads),
    priority => 100,
    max_attempts => 6
  )
  from payloads
)
select count(*) from job_insert_result
$$;

drop table sms.unmatched_delivery_reports;

create index awaiting_resolution_idx on sms.delivery_reports  (created_at, message_service_id) WHERE message_id IS NULL;
create index delivery_report_service_id_idx on sms.delivery_reports (message_service_id) WHERE message_id IS NULL;

alter table sms.delivery_reports drop constraint message_id_required_after_dedicated_unmatched_table;

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
  perform assemble_worker.add_job('forward-delivery-report', v_job, null, 5);
  return NEW;
end;
$$;


DROP TRIGGER _500_foward_delivery_report on sms.delivery_reports;
CREATE TRIGGER _500_foward_delivery_report 
  AFTER INSERT ON sms.delivery_reports 
  FOR EACH ROW 
  WHEN ((new.message_id IS NOT NULL))
  EXECUTE FUNCTION public.trigger_forward_delivery_report_with_profile_info();

alter table sms.delivery_reports drop column is_from_service;
