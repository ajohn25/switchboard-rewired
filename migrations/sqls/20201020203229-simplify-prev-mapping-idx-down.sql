create index outbound_messages_previous_sent_message_query_idx
  on sms.outbound_messages_routing (sending_location_id, to_number, created_at desc);

drop index sms.outbound_messages_routing_to_number_idx;
