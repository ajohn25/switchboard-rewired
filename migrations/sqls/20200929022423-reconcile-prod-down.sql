drop index sms.delivery_reports_created_at_idx;

create index commitment_bucket_under_threshold on sms.fresh_phone_commitments (commitment) where (commitment <= 200);

alter table only sms.outbound_messages
  add constraint outbound_messages_profile_id_fkey
  foreign key (profile_id) references sms.profiles(id);

drop index sms.phone_numbers_phone_number_idx;

drop index sms.outbound_message_from_number_idx;

drop index sms.new_outbound_messages_phone_request_idx;

drop index sms.inbound_message_forward_attempts_message_id_idx;

alter table sms.outbound_messages reset (
  autovacuum_vacuum_threshold,
  autovacuum_vacuum_scale_factor,
  autovacuum_vacuum_cost_limit,
  autovacuum_vacuum_cost_delay
);

alter table sms.fresh_phone_commitments reset (
  autovacuum_vacuum_threshold,
  autovacuum_vacuum_scale_factor,
  autovacuum_vacuum_cost_limit,
  autovacuum_vacuum_cost_delay
);

alter table sms.delivery_reports reset (
  autovacuum_vacuum_threshold,
  autovacuum_vacuum_scale_factor,
  autovacuum_vacuum_cost_limit,
  autovacuum_vacuum_cost_delay
);

comment on function sms.choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid) is '';
