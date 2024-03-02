create index phone_number_is_cordoned_idx on sms.all_phone_numbers (cordoned_at);
drop index sms.phone_number_is_cordoned_partial_idx;

