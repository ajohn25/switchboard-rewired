-- Revert number purchasing
-- --------------------------------

drop trigger _500_bandwidth_complete_basic_purchase on sms.phone_number_requests;

-- Restrict poll-number-order to telnyx
drop trigger _500_poll_number_order_for_readiness on sms.phone_number_requests;
create trigger _500_poll_number_order_for_readiness
  after update
  on sms.phone_number_requests
  for each row
  when (
    (new.service = 'telnyx' and new.phone_number is not null)
    and ((OLD.service_order_id is null) and (NEW.service_order_id is not null))
  )
  execute procedure trigger_job_with_sending_account_info('poll-number-order');


-- Revert addition of Bandwidth sending account
-- --------------------------------------------

drop view sms.sending_accounts_as_json;
create view sms.sending_accounts_as_json as
  select
    sending_accounts.id,
    sending_accounts.display_name,
    sending_accounts.service,
    to_json(sending_accounts.twilio_credentials) as twilio_credentials,
    to_json(sending_accounts.telnyx_credentials) as telnyx_credentials
  from sms.sending_accounts;

comment on view sms.sending_accounts_as_json is '@omit';

alter table sms.sending_accounts
  drop constraint ensure_single_credential,
  drop column bandwidth_credentials;

drop type sms.bandwidth_credentials;
