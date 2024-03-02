-- N.B. fillfactor settings were added manually on most instances. They're not
-- part of our official migrations, however, so ignoring it in the down
-- migration

-- Revert outbound_messages_service_id
-- --------------------------------------------------------

alter index sms.outbound_messages_service_id
  rename to old_outbound_messages_service_id;

create index outbound_messages_service_id
  on sms.outbound_messages (service_id);

drop index sms.old_outbound_messages_service_id;


-- Revert outbound_messages_previous_sent_message_query_idx
-- --------------------------------------------------------

alter index sms.outbound_messages_previous_sent_message_query_idx
  rename to old_outbound_messages_previous_sent_message_query_idx;

create index outbound_messages_previous_sent_message_query_idx
  on sms.outbound_messages (sending_location_id, to_number, created_at desc);

drop index sms.old_outbound_messages_previous_sent_message_query_idx;


-- Restore outbound_messages_phone_number_overloaded_idx
-- --------------------------------------------------------

create index outbound_messages_phone_number_overloaded_idx
  on sms.outbound_messages (processed_at desc, from_number)
  include (estimated_segments)
  where ((stage <> 'awaiting-number'::sms.outbound_message_stages) and (is_current_period = true));


-- Restore outbound_message_from_number_idx
-- --------------------------------------------------------

create index outbound_message_from_number_idx
  on sms.outbound_messages (from_number);
