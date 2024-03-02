drop trigger _500_decomission_phone_number on sms.all_phone_numbers;

create trigger _500_decomission_phone_number
  after update
  on sms.all_phone_numbers
  for each row
  when (old.released_at IS NULL AND new.released_at IS NOT NULL)
  execute procedure public.trigger_job_with_sending_account_info('sell-number');

DROP FUNCTION public.trigger_sell_number();

