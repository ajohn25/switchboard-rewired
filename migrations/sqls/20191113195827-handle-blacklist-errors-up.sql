alter table sms.delivery_reports alter column message_service_id drop not null;

-- Run outside of transaction block
-- alter type sms.outbound_message_stages add value 'failed';
