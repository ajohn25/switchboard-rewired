-- Add Bandwidth Dry Run enum value
-- -------------------------------------------

do $$
begin
  alter type sms.profile_service_option add value 'bandwidth-dry-run';
  exception when duplicate_object then
  raise notice 'not adding service option ''bandwidth-dry-run'' -- it already exists';
end $$;
