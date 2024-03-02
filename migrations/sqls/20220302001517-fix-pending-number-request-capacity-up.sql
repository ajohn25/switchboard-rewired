CREATE OR REPLACE VIEW sms.pending_number_request_capacity AS
 SELECT pending_number_request_id, count(*) as commitment_count
   FROM sms.outbound_messages_awaiting_from_number
  GROUP BY 1
 UNION
 SELECT id as pending_number_request_id, 0 as commitment_count
   FROM sms.phone_number_requests
   WHERE id not in ( select pending_number_request_id from sms.outbound_messages_awaiting_from_number );

DROP TRIGGER _500_increment_pending_request_commitment_after_insert ON sms.outbound_messages_routing;
DROP TRIGGER _500_increment_pending_request_commitment_after_update ON sms.outbound_messages_routing;
