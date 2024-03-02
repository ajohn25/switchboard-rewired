drop index sms.awaiting_resolution_idx;
drop function sms.resolve_delivery_reports;

create trigger _500_update_delivery_reports_with_message_id
  after update
  on sms.outbound_messages
  for each row
  when (NEW.service_id is not null and OLD.service_id is null)
  execute procedure sms.tg__outbound_messages__update_delivery_reports_with_message_id();

create or replace function sms.tg__delivery_reports__find_message_id() returns trigger as $$
declare
  v_message_id uuid;
begin
  select id
  from sms.outbound_messages
  where service_id = NEW.message_service_id
  into v_message_id;

  NEW.message_id = v_message_id;
  return NEW;
end;
$$ language plpgsql;

create trigger _500_find_message_id
  before insert
  on sms.delivery_reports
  for each row
  when (NEW.message_id is null)
  execute procedure sms.tg__delivery_reports__find_message_id();

create  trigger _500_forward_delivery_report
  after update
  on sms.delivery_reports
  for each row
  when (new.message_id is not null and old.message_id is null)
  execute procedure trigger_job_with_profile_info('forward-delivery-report');
