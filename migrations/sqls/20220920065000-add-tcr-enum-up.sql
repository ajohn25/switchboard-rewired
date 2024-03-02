-- Add TCR enum in separate transaction
-- -------------------------------------------

do $$
begin
  alter type sms.profile_service_option add value 'tcr';
  exception when duplicate_object then
  raise notice 'not adding service option ''tcr'' -- it already exists';
end $$;
