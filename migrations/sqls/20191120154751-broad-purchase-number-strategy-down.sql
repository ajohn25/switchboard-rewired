drop trigger _500_inherit_purchasing_strategy on sms.sending_locations;
drop function sms.tg__sending_locations__strategy_inherit;

drop trigger _500_find_suitable_area_codes on sms.sending_locations;

drop function sms.queue_find_suitable_area_codes_refresh;
drop function sms.compute_sending_location_capacity;

drop trigger _500_queue_determine_area_code_capacity_after_update on sms.sending_locations;
create trigger _500_queue_determine_area_code_capacity_after_update
  after update
  on sms.sending_locations
  for each row
  when (OLD.area_codes <> NEW.area_codes and array_length(NEW.area_codes, 1) > 0)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');

drop trigger _500_queue_determine_area_code_capacity_after_insert on sms.sending_locations;
create trigger _500_queue_determine_area_code_capacity_after_insert
  after insert
  on sms.sending_locations
  for each row
  when (NEW.area_codes is not null and array_length(NEW.area_codes, 1) > 0)
  execute procedure trigger_job_with_sending_account_info('estimate-area-code-capacity');

alter table sms.profiles drop column default_purchasing_strategy;
alter table sms.sending_locations drop column purchasing_strategy;

drop type sms.number_purchasing_strategy cascade;
