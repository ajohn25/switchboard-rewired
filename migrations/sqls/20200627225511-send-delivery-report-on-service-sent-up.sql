create or replace function sms.tg__outbound_messages__send_delivery_report_for_sent() returns trigger as $$
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
$$ language plpgsql volatile strict;


create trigger _500_send_delivery_report_with_segment_counts
  after update
  on sms.outbound_messages
  for each row
  when (OLD.stage <> 'sent' and NEW.stage = 'sent')
  execute procedure sms.tg__outbound_messages__send_delivery_report_for_sent();
