CREATE OR REPLACE FUNCTION public.trigger_sell_number() RETURNS trigger
    LANGUAGE plpgsql STRICT SECURITY DEFINER
    SET search_path TO '$user', 'public'
    AS $$
declare
  v_job json;
  v_sending_location_id uuid;
  v_sending_account_json json;
begin
  select row_to_json(NEW) into v_job;

  if TG_TABLE_NAME = 'sending_locations' then
    v_sending_location_id := NEW.id;
  else
    v_sending_location_id := NEW.sending_location_id;
  end if;

  select row_to_json(relevant_sending_account_fields)
  from (
    select sending_account.id as sending_account_id, sending_account.service, sending_account.twilio_credentials, sending_account.telnyx_credentials
      from sms.sending_locations
      join sms.profiles on sms.sending_locations.profile_id = sms.profiles.id
      join sms.sending_accounts_as_json as sending_account
        on sending_account.id = sms.profiles.sending_account_id
    where sms.sending_locations.id = v_sending_location_id
  ) relevant_sending_account_fields
  into v_sending_account_json;

  select v_job::jsonb || v_sending_account_json::jsonb into v_job;
  perform graphile_worker.add_job('sell-number', v_job, queue_name => 'sell-number', max_attempts => 5);
  return NEW;
end;
$$;

drop trigger _500_decomission_phone_number on sms.all_phone_numbers;

create trigger _500_decomission_phone_number
  after update
  on sms.all_phone_numbers
  for each row
  when (old.released_at IS NULL AND new.released_at IS NOT NULL)
  execute procedure public.trigger_sell_number();

