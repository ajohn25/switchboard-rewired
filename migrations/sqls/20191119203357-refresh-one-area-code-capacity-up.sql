create or replace function sms.refresh_one_area_code_capacity(area_code area_code, sending_account_id uuid) returns void as $$
begin
  perform assemble_worker.add_job('estimate-area-code-capacity', row_to_json(all_area_code_capacity_job_info))
  from (
    select
      sms.area_code_capacities.sending_account_id,
      ARRAY[sms.area_code_capacities.area_code] as area_codes,
      sms.sending_accounts.service,
      sms.sending_accounts.twilio_credentials,
      sms.sending_accounts.telnyx_credentials
    from sms.area_code_capacities
    join sms.sending_accounts
      on sms.sending_accounts.id = sms.area_code_capacities.sending_account_id
    where sms.sending_accounts.id = refresh_one_area_code_capacity.sending_account_id
      and sms.area_code_capacities.area_code = refresh_one_area_code_capacity.area_code
  ) as all_area_code_capacity_job_info;
end;
$$ language plpgsql;



