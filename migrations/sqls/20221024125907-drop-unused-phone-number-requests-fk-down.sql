alter table sms.outbound_messages
  add constraint outbound_messages_sending_location_id_fkey
    foreign key (sending_location_id)
    references sms.sending_locations (id),
  add constraint outbound_messages_pending_number_request_id_fkey
    foreign key (pending_number_request_id)
    references sms.phone_number_requests(id);
