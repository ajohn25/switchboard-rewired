drop trigger _500_bandwidth_associate_10dlc_campaign on sms.phone_number_requests;

-- Associate 10DLC campaign after service order completion IFF it IS a 10DLC campaign
create trigger _500_bandwidth_associate_10dlc_campaign
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'bandwidth' and new.service_10dlc_campaign_id is not null)
    and ((old.service_order_completed_at is null) and (new.service_order_completed_at is not null))
  )
  execute procedure trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign');
