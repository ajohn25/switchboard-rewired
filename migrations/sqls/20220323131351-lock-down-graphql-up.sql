-- Lock down exposed GraphQL schema
-- --------------------------------------------

comment on table sms.fresh_phone_commitments is E'@omit';
comment on table sms.outbound_messages_awaiting_from_number is E'@omit';
comment on table sms.outbound_messages_routing is E'@omit';
comment on table sms.outbound_messages_telco is E'@omit';

comment on function sms.resolve_delivery_reports is E'@omit';
comment on function sms.sell_cordoned_numbers is E'@omit';
comment on function sms.sending_locations_active_phone_number_count is E'@omit';
comment on function sms.compute_sending_location_capacity is E'@omit';
comment on function sms.estimate_segments is E'@omit';
comment on function sms.process_grey_route_message is E'@omit';
comment on function sms.choose_existing_available_number is E'@omit';
comment on function sms.backfill_commitment_buckets is E'@omit';
comment on function sms.backfill_pending_request_commitment_counts is E'@omit';
comment on function sms.queue_find_suitable_area_codes_refresh is E'@omit';
comment on function sms.refresh_area_code_capacity_estimates is E'@omit';
comment on function sms.refresh_one_area_code_capacity is E'@omit';
comment on function sms.reset_sending_location_state_and_locations is E'@omit';
comment on procedure sms.backfill_telco_profile_id is E'@omit';
