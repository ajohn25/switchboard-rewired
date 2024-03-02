--- Revert sms.resolve_delivery_reports
--- ---------------------------------------------

create or replace function sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval)
returns bigint as $$ 
  with update_result as (
    update sms.delivery_reports
    set message_id = sms.outbound_messages.id
    from sms.outbound_messages
    where sms.delivery_reports.message_service_id = sms.outbound_messages.service_id
      and sms.delivery_reports.message_id is null
      and sms.delivery_reports.created_at >= now() - as_far_back_as
      and sms.delivery_reports.created_at <= now() - as_recent_as
    returning
      sms.delivery_reports.*,
      sms.outbound_messages.sending_location_id
  ),
  job_insert_result as (
    insert into assemble_worker.jobs(
      queue_name,
      payload,
      max_attempts,
      run_at,
      status
    )
    select
      'forward-delivery-report',
      row_to_json(update_result)::jsonb || row_to_json(relevant_profile_fields)::jsonb,
      6,
      null,
      'running'
    from update_result
    join (
      select
        profiles.id as profile_id,
        clients.access_token as encrypted_client_access_token,
        sms.sending_locations.id as sending_location_id,
        profiles.message_status_webhook_url,
        profiles.reply_webhook_url
      from sms.sending_locations
      join sms.profiles as profiles on profiles.id = sms.sending_locations.profile_id
      join billing.clients as clients on clients.id = profiles.client_id
    ) relevant_profile_fields
      on relevant_profile_fields.sending_location_id = update_result.sending_location_id
    returning 1
  )
  select count(*) from job_insert_result
$$ language sql strict;


--- Drop sms.outbound_messages_teclo
--- ---------------------------------------------

drop table sms.outbound_messages_telco;
drop type sms.telco_status;

CREATE FUNCTION sms.tg__outbound_messages__send_delivery_report_for_sent() RETURNS trigger
    LANGUAGE plpgsql STRICT
    AS $$
declare
  v_service sms.profile_service_option;
begin
  select service
  into v_service
  from sms.sending_accounts
  join sms.profiles
    on sms.profiles.sending_account_id = sms.sending_accounts.id
  where sms.profiles.id = NEW.profile_id;

  insert into sms.delivery_reports (
    message_service_id,
    message_id,
    event_type,
    generated_at,
    validated,
    service,
    extra
  ) values (
    NEW.service_id,
    NEW.id,
    'sent',
    now(),
    true,
    v_service,
    json_build_object(
      'num_segments', NEW.num_segments,
      'num_media', NEW.num_media
    )
  );

  return NEW;
end;
$$;

CREATE TRIGGER _500_send_delivery_report_with_segment_counts
  AFTER UPDATE
  ON sms.outbound_messages 
  FOR EACH ROW
  WHEN (((old.stage <> 'sent'::sms.outbound_message_stages) AND (new.stage = 'sent'::sms.outbound_message_stages)))
  EXECUTE PROCEDURE sms.tg__outbound_messages__send_delivery_report_for_sent();


