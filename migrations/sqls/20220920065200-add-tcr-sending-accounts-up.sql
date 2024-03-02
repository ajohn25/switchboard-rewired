-- Add TCR Credentials
-- --------------------------------------------

create type sms.tcr_credentials as (
  api_key_label text,
  api_key text,
  encrypted_secret text
);

alter table sms.sending_accounts
  add column tcr_credentials sms.tcr_credentials,
  drop constraint ensure_single_credential,
  add constraint ensure_single_credential
    check (num_nonnulls(twilio_credentials, telnyx_credentials, bandwidth_credentials, tcr_credentials) <= 1);

drop view sms.sending_accounts_as_json;
create view sms.sending_accounts_as_json as
  select
    sending_accounts.id,
    sending_accounts.display_name,
    sending_accounts.service,
    to_json(sending_accounts.twilio_credentials) as twilio_credentials,
    to_json(sending_accounts.telnyx_credentials) as telnyx_credentials,
    to_json(sending_accounts.bandwidth_credentials) as bandwidth_credentials,
    to_json(sending_accounts.tcr_credentials) as tcr_credentials
  from sms.sending_accounts;

comment on view sms.sending_accounts_as_json is '@omit';
grant select on sms.sending_accounts_as_json to client;
