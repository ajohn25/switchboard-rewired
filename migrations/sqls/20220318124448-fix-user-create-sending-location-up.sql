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
