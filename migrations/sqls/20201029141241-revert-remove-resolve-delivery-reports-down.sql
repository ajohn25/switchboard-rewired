CREATE TRIGGER _500_foward_delivery_report_without_profile_info
  AFTER INSERT ON sms.delivery_reports 
  FOR EACH ROW
  WHEN (new.message_id IS NULL)
  EXECUTE PROCEDURE public.trigger_forward_delivery_report_without_profile_info(); 


