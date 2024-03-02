drop index sms.phone_number_is_cordoned_idx;
create index phone_number_is_cordoned_partial_idx on sms.all_phone_numbers (cordoned_at) where released_at is null;

-- If running during production hours:
  -- create index CONCURRENTLY phone_number_is_cordoned_partial_idx on sms.all_phone_numbers (cordoned_at) where released_at is null;
  -- drop index CONCURRENTLY sms.phone_number_is_cordoned_idx;

