-- Disable update_is_current_period_indexes() until we figure out chunking it
create or replace function sms.update_is_current_period_indexes() returns bigint language sql strict as $$
  select 1::bigint;
$$;
