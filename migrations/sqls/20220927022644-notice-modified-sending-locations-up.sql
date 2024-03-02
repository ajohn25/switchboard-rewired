create trigger _500_notice_new_sending_location
  after insert
  on sms.sending_locations
  for each row
  execute procedure trigger_job('notice-sending-location-change');

create trigger _500_notice_modified_sending_location
  after update
  on sms.sending_locations
  for each row
  execute procedure trigger_job('notice-sending-location-change');
