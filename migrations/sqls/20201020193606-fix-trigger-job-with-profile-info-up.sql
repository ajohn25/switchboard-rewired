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

drop trigger _500_foward_delivery_report on sms.delivery_reports;

create trigger _500_foward_delivery_report
  after insert
  on sms.delivery_reports
  for each row
  when (NEW.message_id is not null)
  execute procedure trigger_forward_delivery_report_with_profile_info();

