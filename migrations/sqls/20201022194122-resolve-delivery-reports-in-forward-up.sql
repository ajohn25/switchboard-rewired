CREATE FUNCTION public.trigger_forward_delivery_report_without_profile_info() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
begin
  select row_to_json(NEW) into v_job;

  perform graphile_worker.add_job(
    'forward-delivery-report',
    v_job,
    max_attempts => 5
  );

  return NEW;
end;
$$;

CREATE TRIGGER _500_foward_delivery_report_without_profile_info
  AFTER INSERT ON sms.delivery_reports 
  FOR EACH ROW
  WHEN (new.message_id IS NULL)
  EXECUTE PROCEDURE public.trigger_forward_delivery_report_without_profile_info(); 
