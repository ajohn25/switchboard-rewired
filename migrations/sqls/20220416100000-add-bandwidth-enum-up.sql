-- Add Bandwidth enum in separate transaction
-- -------------------------------------------

do $$
begin
  alter type sms.profile_service_option add value 'bandwidth';
  exception when duplicate_object then
  raise notice 'not adding service option ''bandiwdth'' -- it already exists';
end $$;
