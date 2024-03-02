drop index sms.from_number_mappings_from_number_idx;

create index from_number_mappings_from_number_idx
  on sms.from_number_mappings (from_number) where invalidated_at is null;
