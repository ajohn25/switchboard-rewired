create index outbound_messages_routing_to_number_idx
  on sms.outbound_messages_routing (to_number);

drop index sms.outbound_messages_previous_sent_message_query_idx;

/*
create index concurrently outbound_messages_routing_to_number_idx
  on sms.outbound_messages_routing (to_number);

drop index concurrently sms.outbound_messages_previous_sent_message_query_idx;
*/
