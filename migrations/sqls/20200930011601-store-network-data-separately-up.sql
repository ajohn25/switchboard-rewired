--- Create sms.outbound_messages_telco
--- ---------------------------------------------

drop trigger _500_send_delivery_report_with_segment_counts on sms.outbound_messages;
drop function sms.tg__outbound_messages__send_delivery_report_for_sent;

create type sms.telco_status as enum (
  'sent',
  'delivered',
  'failed'
);

create table sms.outbound_messages_telco (
  id uuid not null,
  service_id text,
  telco_status sms.telco_status not null default 'sent'::sms.telco_status,
  num_segments integer,
  num_media integer,
  cost_in_cents numeric(6,2),
  extra json
);

create index outbound_messages_telco_service_id
  on sms.outbound_messages_telco (service_id);

alter table only sms.outbound_messages_telco
  add constraint outbound_messages_telco_pkey primary key (id),
  add constraint outbound_messages_telco_id_fkey
    foreign key (id)
    references sms.outbound_messages(id)
    on delete cascade;

--- Update sms.resolve_delivery_reports
--- ---------------------------------------------

create or replace function sms.resolve_delivery_reports(as_far_back_as interval, as_recent_as interval)
returns bigint as $$ 
  with update_result as (
    update sms.delivery_reports
    set message_id = sms.outbound_messages_telco.id
    from sms.outbound_messages_telco
    where sms.delivery_reports.message_service_id = sms.outbound_messages_telco.service_id
      and sms.delivery_reports.message_id is null
      and sms.delivery_reports.created_at >= now() - as_far_back_as
      and sms.delivery_reports.created_at <= now() - as_recent_as
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
      (
        coalesce(update_result.extra, '{}'::json)::jsonb || json_build_object(
          'num_segments', sms.outbound_messages_telco.num_segments,
          'num_media', sms.outbound_messages_telco.num_media
        )::jsonb
      )::json as extra
    from update_result
    join sms.outbound_messages_telco
      on update_result.message_id = sms.outbound_messages_telco.id
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
      row_to_json(payloads)::jsonb || row_to_json(relevant_profile_fields)::jsonb,
      6,
      null,
      'running'
    from payloads
    join (
      select
        outbound_messages.id as message_id,
        profiles.id as profile_id,
        clients.access_token as encrypted_client_access_token,
        sms.sending_locations.id as sending_location_id,
        profiles.message_status_webhook_url,
        profiles.reply_webhook_url
      from sms.outbound_messages as outbound_messages
      join sms.sending_locations
        on sms.sending_locations.id = outbound_messages.sending_location_id
      join sms.profiles as profiles on profiles.id = sms.sending_locations.profile_id
      join billing.clients as clients on clients.id = profiles.client_id
    ) relevant_profile_fields
      on relevant_profile_fields.message_id = payloads.message_id
    returning 1
  )
  select count(*) from job_insert_result
$$ language sql strict;


