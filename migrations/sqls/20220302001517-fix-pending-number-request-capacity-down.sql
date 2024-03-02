CREATE OR REPLACE VIEW sms.pending_number_request_capacity AS
 SELECT phone_number_requests.id AS pending_number_request_id,
    phone_number_requests.commitment_count
   FROM sms.phone_number_requests
  WHERE phone_number_requests.fulfilled_at IS NULL;


CREATE TRIGGER _500_increment_pending_request_commitment_after_insert 
  AFTER INSERT ON sms.outbound_messages_routing 
  FOR EACH ROW 
  WHEN ((new.pending_number_request_id IS NOT NULL)) 
  EXECUTE FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment();

CREATE TRIGGER _500_increment_pending_request_commitment_after_update 
  AFTER UPDATE ON sms.outbound_messages_routing 
  FOR EACH ROW 
  WHEN (
    ((new.pending_number_request_id IS NOT NULL) AND (old.pending_number_request_id IS NULL))
  ) 
  EXECUTE FUNCTION sms.tg__outbound_messages__increment_pending_request_commitment();
