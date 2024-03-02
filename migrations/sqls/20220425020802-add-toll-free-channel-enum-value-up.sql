-- Add toll-free enum value
-- --------------------------------------------

do $$
begin
  alter type sms.traffic_channel add value 'toll-free';
  exception when duplicate_object then
  raise notice 'not adding channel option ''toll-free'' -- it already exists';
end $$;
