DROP TRIGGER _500_foward_delivery_report_without_profile_info
  ON sms.delivery_reports;

DROP FUNCTION public.trigger_forward_delivery_report_without_profile_info();
