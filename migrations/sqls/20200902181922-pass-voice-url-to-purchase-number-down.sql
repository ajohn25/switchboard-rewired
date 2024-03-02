drop trigger _500_purchase_number on sms.phone_number_requests;

create trigger _500_purchase_number
  after insert
  on sms.phone_number_requests
  for each row
  execute procedure trigger_job_with_sending_account_info('purchase-number');

drop function trigger_job_with_sending_account_and_profile_info;

alter table sms.profiles drop column voice_callback_url;

