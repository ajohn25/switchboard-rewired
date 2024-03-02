-- Revert exposing GraphQL schema
-- --------------------------------------------

comment on function sms.resolve_delivery_reports is null;
comment on function sms.sell_cordoned_numbers is null;
comment on function sms.sending_locations_active_phone_number_count is null;
comment on function sms.compute_sending_location_capacity is null;
comment on function sms.estimate_segments is null;
comment on function sms.process_grey_route_message is null;
comment on function sms.choose_existing_available_number is null;
comment on function sms.backfill_commitment_buckets is null;
comment on function sms.backfill_pending_request_commitment_counts is null;
comment on function sms.queue_find_suitable_area_codes_refresh is null;
comment on function sms.refresh_area_code_capacity_estimates is null;
comment on function sms.refresh_one_area_code_capacity is null;
comment on function sms.reset_sending_location_state_and_locations is null;
comment on procedure sms.backfill_telco_profile_id is null;

comment on table sms.fresh_phone_commitments is null;
comment on table sms.outbound_messages_awaiting_from_number is null;
comment on table sms.outbound_messages_routing is null;
comment on table sms.outbound_messages_telco is null;
