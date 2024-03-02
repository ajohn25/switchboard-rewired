-- Revert 10DLC process-message
-- ------------------------------------

drop function sms.process_10dlc_message(sms.outbound_messages, interval);


-- Revert profile provisioned trigger
-- ------------------------------------

CREATE OR REPLACE FUNCTION sms.tg__sync_profile_provisioned() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
    AS $$
declare
  v_profile_ids uuid[];
begin
  update sms.profiles
  set
    provisioned = exists (
      select 1
      from sms.sending_locations
      where
        profile_id = profiles.id
        and decomissioned_at is null
    )
  where
    id = ANY(array[OLD.profile_id, NEW.profile_id])
    and channel = 'grey-route';

  return NEW;
end;
$$;


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
  elsif v_channel = 'toll-free'::sms.traffic_channel then
    perform assemble_worker.add_job('process-toll-free-message', v_job, null, 5);
  else
    raise 'Unsupported traffic channel %', v_channel;
  end if;

  return NEW;
end;
$$ language plpgsql;


-- Remove check from profiles
-- ------------------------------------

alter table sms.profiles
  drop constraint valid_10dlc_channel;
