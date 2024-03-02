-- Revert sms.update_is_current_period_indexes()
create or replace function sms.update_is_current_period_indexes() returns bigint
  language sql strict
  as $$
with update_routing_result as (
  update sms.outbound_messages_routing
  set is_current_period = false
  where
    is_current_period = true
    and processed_at < date_trunc('day', now())
  returning 1
),
update_messages_result as (
  update sms.outbound_messages
  set is_current_period = false
  where
    is_current_period = true
    and processed_at < date_trunc('day', now())
  returning 1
)
select count(*)
from (
  select * from update_routing_result
  union
  select * from update_messages_result
) counts;
$$;
