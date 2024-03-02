drop trigger _500_update_delivery_reports_with_message_id on sms.outbound_messages;
drop trigger _500_find_message_id on sms.delivery_reports;
drop trigger _500_forward_delivery_report on sms.delivery_reports;

create index awaiting_resolution_idx on sms.delivery_reports (created_at, message_service_id)
  where (message_id is null);

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


