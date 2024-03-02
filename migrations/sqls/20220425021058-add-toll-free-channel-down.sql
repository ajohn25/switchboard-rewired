-- Revert toll-free process-message
-- ------------------------------------

drop function sms.process_toll_free_message(sms.outbound_messages, interval);


-- Revert outbound message trigger
-- ------------------------------------

create or replace function sms.tg__trigger_process_message() returns trigger as $$
declare
  v_channel sms.traffic_channel;
  v_job json;
begin
  select coalesce(channel, 'grey-route'::sms.traffic_channel)
  from sms.profiles
  where id = NEW.profile_id
  into v_channel;

  select row_to_json(NEW) into v_job;

  if v_channel = 'grey-route'::sms.traffic_channel then
    perform assemble_worker.add_job('process-grey-route-message', v_job, null, 5);
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$ language plpgsql;


-- Revert sync toll-free provisioned status
-- --------------------------------------------

drop trigger _700_sync_profile_provisioned on sms.toll_free_use_cases;
drop trigger _700_sync_profile_provisioned_after_update on sms.toll_free_use_cases;
drop function sms.tg__sync_toll_free_profile_provisioned();


-- Revert reference from profiles
-- ------------------------------------

alter table sms.profiles
  drop constraint valid_toll_free_channel,
  drop column toll_free_use_case_id;


-- Drop toll-free table
-- ----------------------------

drop table sms.toll_free_use_cases;
