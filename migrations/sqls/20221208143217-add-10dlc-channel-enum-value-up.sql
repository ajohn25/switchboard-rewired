-- Add 10dlc enum value
-- --------------------------------------------

do $$
begin
  alter type sms.traffic_channel add value '10dlc';
  exception when duplicate_object then
  raise notice 'not adding channel option ''10dlc'' -- it already exists';
end $$;
