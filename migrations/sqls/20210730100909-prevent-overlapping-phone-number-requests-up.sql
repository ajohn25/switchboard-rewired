-- Google Cloud SQL does not allow setting session_replication_role
-- so we disable the trigger by dropping and recreating
drop trigger _500_poll_number_order_for_readiness
  on sms.phone_number_requests;

update sms.phone_number_requests pnr
set service_order_id = 'legacy'
where true
  and service_order_id is null
  and fulfilled_at is not null;

create unique index unqiue_number_for_unfulfilled_service_order_id on sms.phone_number_requests ( phone_number ) where service_order_id is null;
create unique index unqiue_number_for_unfulfilled_fulfilled_at on sms.phone_number_requests ( phone_number ) where fulfilled_at is null;

create trigger _500_poll_number_order_for_readiness
  after update
  on sms.phone_number_requests
  for each row
  when (old.service_order_id is null and new.service_order_id is not null)
  execute procedure trigger_job_with_sending_account_info('poll-number-order');
