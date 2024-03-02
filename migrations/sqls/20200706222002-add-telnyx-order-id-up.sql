alter table sms.phone_number_requests
  add column service_order_id text;

create trigger _500_poll_number_order_for_readiness
  after update on sms.phone_number_requests
  for each row when (OLD.service_order_id is null and NEW.service_order_id is not null)
  execute procedure trigger_job_with_sending_account_info('poll-number-order');
