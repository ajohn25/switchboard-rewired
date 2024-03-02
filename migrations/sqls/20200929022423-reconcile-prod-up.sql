comment on function sms.choose_sending_location_for_contact(contact_zip_code public.zip_code, profile_id uuid) is '@omit';

-- Holding off on fillfactor for professional advice
alter table sms.delivery_reports set (
  autovacuum_vacuum_threshold=50000,
  autovacuum_vacuum_scale_factor=0,
  autovacuum_vacuum_cost_limit=1000,
  autovacuum_vacuum_cost_delay=0
);

-- Holding off on fillfactor for professional advice
alter table sms.fresh_phone_commitments set (
  autovacuum_vacuum_threshold=50000,
  autovacuum_vacuum_scale_factor=0,
  autovacuum_vacuum_cost_limit=1000,
  autovacuum_vacuum_cost_delay=0
);

-- Holding off on fillfactor for professional advice
alter table sms.outbound_messages set (
  autovacuum_vacuum_threshold=50000,
  autovacuum_vacuum_scale_factor=0,
  autovacuum_vacuum_cost_limit=1000,
  autovacuum_vacuum_cost_delay=0
);

create index inbound_message_forward_attempts_message_id_idx
  on sms.inbound_message_forward_attempts using btree (message_id);

create index new_outbound_messages_phone_request_idx
  on sms.outbound_messages using btree (pending_number_request_id)
  where (stage = 'awaiting-number'::sms.outbound_message_stages);

create index outbound_message_from_number_idx
  on sms.outbound_messages using btree (from_number);

create index phone_numbers_phone_number_idx on sms.all_phone_numbers using btree (phone_number);

-- We trust this is valid from the sending_location_id fk
alter table only sms.outbound_messages
  drop constraint outbound_messages_profile_id_fkey;

drop index sms.commitment_bucket_under_threshold;

create index delivery_reports_created_at_idx
  on sms.delivery_reports using btree (created_at, event_type);
