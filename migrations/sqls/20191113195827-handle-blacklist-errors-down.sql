-- This will lock the table
alter table sms.delivery_reports alter column message_service_id set not null;

-- No easy way to undo the below - cant remove values from enum
-- alter type sms.outbound_message_stages add value 'failed';
