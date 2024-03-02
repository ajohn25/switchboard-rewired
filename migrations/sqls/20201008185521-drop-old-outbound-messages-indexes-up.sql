-- outbound_message_from_number_idx
-- --------------------------------------------------------

drop index sms.outbound_message_from_number_idx;


-- outbound_messages_phone_number_overloaded_idx
-- --------------------------------------------------------

drop index sms.outbound_messages_phone_number_overloaded_idx;


-- outbound_messages_previous_sent_message_query_idx
-- --------------------------------------------------------

alter index sms.outbound_messages_previous_sent_message_query_idx
  rename to old_outbound_messages_previous_sent_message_query_idx;

create index outbound_messages_previous_sent_message_query_idx
  on sms.outbound_messages (sending_location_id, to_number, created_at desc)
  where (sending_location_id is not null);

drop index sms.old_outbound_messages_previous_sent_message_query_idx;


-- outbound_messages_service_id
-- --------------------------------------------------------

alter index sms.outbound_messages_service_id
  rename to old_outbound_messages_service_id;

create index outbound_messages_service_id
  on sms.outbound_messages (service_id)
  where (service_id is not null);

drop index sms.old_outbound_messages_service_id;
