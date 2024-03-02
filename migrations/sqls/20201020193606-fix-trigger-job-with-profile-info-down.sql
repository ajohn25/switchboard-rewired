drop trigger _500_foward_delivery_report on sms.delivery_reports;

create trigger _500_foward_delivery_report
  after insert
  on sms.delivery_reports
  for each row
  when (NEW.message_id is not null)
  execute procedure trigger_job_with_profile_info('forward-delivery-report');

DROP FUNCTION public.trigger_forward_delivery_report_with_profile_info();

