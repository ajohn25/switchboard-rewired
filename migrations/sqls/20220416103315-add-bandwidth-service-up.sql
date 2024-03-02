-- Add Bandwidth sending account
-- --------------------------------

create type sms.bandwidth_credentials as (
  account_id text,
  username text,
  encrypted_password text,
  site_id text,
  location_id text,
  application_id text,
  callback_username text,
  callback_encrypted_password text
);

alter table sms.sending_accounts
  add column bandwidth_credentials sms.bandwidth_credentials,
  add constraint ensure_single_credential
    check (num_nonnulls(twilio_credentials, telnyx_credentials, bandwidth_credentials) <= 1);

drop view sms.sending_accounts_as_json;
create view sms.sending_accounts_as_json as
  select
    sending_accounts.id,
    sending_accounts.display_name,
    sending_accounts.service,
    to_json(sending_accounts.twilio_credentials) as twilio_credentials,
    to_json(sending_accounts.telnyx_credentials) as telnyx_credentials,
    to_json(sending_accounts.bandwidth_credentials) as bandwidth_credentials
  from sms.sending_accounts;

comment on view sms.sending_accounts_as_json is '@omit';
grant select on sms.sending_accounts_as_json to client;


-- Update number purchasing
-- --------------------------------

-- Restrict poll-number-order to telnyx and bandwidth
drop trigger _500_poll_number_order_for_readiness on sms.phone_number_requests;
create trigger _500_poll_number_order_for_readiness
  after update
  on sms.phone_number_requests
  for each row
  when (
    ((NEW.service = 'telnyx' or NEW.service = 'bandwidth') and NEW.phone_number is not null)
    and ((OLD.service_order_id is null) and (NEW.service_order_id is not null))
  )
  execute procedure trigger_job_with_sending_account_info('poll-number-order');

-- Complete purchase after messaging profile association IFF it IS NOT a 10DLC campaign
create trigger _500_bandwidth_complete_basic_purchase
  before update
  on sms.phone_number_requests
  for each row
  when (
    (NEW.service = 'bandwidth' and NEW.service_10dlc_campaign_id is null)
    and ((OLD.service_order_completed_at is null) and (NEW.service_order_completed_at is not null))
  )
  execute procedure sms.tg__complete_number_purchase();
