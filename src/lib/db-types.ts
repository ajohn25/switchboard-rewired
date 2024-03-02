export enum outbound_message_stages {
  'Failed' = 'failed',
  'Sent' = 'sent',
  'Queued' = 'queued',
  'AwaitingNumber' = 'awaiting-number',
  'Processing' = 'processing',
}

export enum profile_service_option {
  'Bandwidth' = 'bandwidth',
  'BandwidthDryRun' = 'bandwidth-dry-run',
  'Telnyx' = 'telnyx',
  'Twilio' = 'twilio',
}

export enum delivery_report_event {
  'DeliveryUnconfirmed' = 'delivery_unconfirmed',
  'DeliveryFailed' = 'delivery_failed',
  'SendingFailed' = 'sending_failed',
  'Delivered' = 'delivered',
  'Sent' = 'sent',
  'Sending' = 'sending',
  'Queued' = 'queued',
}

export enum number_purchasing_strategy {
  'SameStateByDistance' = 'same-state-by-distance',
  'ExactAreaCodes' = 'exact-area-codes',
}

export enum telco_status {
  'Failed' = 'failed',
  'Delivered' = 'delivered',
  'Sent' = 'sent',
}

export enum traffic_channel {
  'TollFree' = 'toll-free',
  'GreyRoute' = 'grey-route',
  '10DLC' = '10dlc',
}

export interface active_previous_mapping_pairings {
  profile_id?: string | null;
  to_number?: string | null;
  from_number?: string | null;
  last_used_at?: Date | null;
  sending_location_id?: string | null;
  cordoned_at?: Date | null;
  invalidated_at?: Date | null;
}

export interface all_phone_numbers {
  phone_number: string;
  created_at: Date;
  released_at?: Date | null;
  sending_location_id: string;
  id: string;
  sold_at?: Date | null;
  cordoned_at?: Date | null;
}

export interface area_code_capacities {
  area_code: string;
  sending_account_id: string;
  capacity?: number | null;
  last_fetched_at?: Date | null;
}

export interface delivery_report_forward_attempts {
  message_id: string;
  event_type: delivery_report_event;
  sent_at: Date;
  sent_headers: unknown;
  sent_body: unknown;
  response_status_code: number;
  response_headers: unknown;
  response_body?: string | null;
}

export interface delivery_reports {
  message_service_id?: string | null;
  message_id?: string | null;
  event_type: delivery_report_event;
  generated_at: Date;
  created_at: Date;
  service: string;
  validated: boolean;
  error_codes?: string[] | null;
  extra: any | null;
  is_from_service?: boolean | null;
}

export interface fresh_phone_commitments {
  phone_number: string;
  commitment?: number | null;
  sending_location_id: string;
}

export interface inbound_message_forward_attempts {
  message_id?: string | null;
  sent_at: Date;
  sent_headers: unknown;
  sent_body: unknown;
  response_status_code: number;
  response_headers: unknown;
  response_body?: string | null;
}

export interface inbound_messages {
  id: string;
  sending_location_id: string;
  from_number: string;
  to_number: string;
  body: string;
  received_at: Date;
  service: profile_service_option;
  service_id: string;
  num_segments: number;
  num_media: number;
  validated: boolean;
  media_urls?: any[] | null;
  extra?: unknown | null;
}

export interface outbound_messages {
  id: string;
  sending_location_id?: string | null;
  created_at: Date;
  contact_zip_code: string;
  stage: outbound_message_stages;
  to_number: string;
  from_number?: string | null;
  pending_number_request_id?: string | null;
  body: string;
  media_urls?: any[] | null;
  service_id?: string | null;
  num_segments?: number | null;
  num_media?: number | null;
  extra?: unknown | null;
  decision_stage?: string | null;
  estimated_segments?: number | null;
  send_after?: Date | null;
  profile_id?: string | null;
  processed_at?: Date | null;
  cost_in_cents?: number | null;
  first_from_to_pair_of_day?: boolean | null;
  send_before?: Date | null;
}

export interface outbound_messages_awaiting_from_number {
  id: string;
  original_created_at: Date;
  to_number: string;
  estimated_segments?: number | null;
  sending_location_id: string;
  pending_number_request_id: string;
  send_after?: Date | null;
  processed_at?: Date | null;
  decision_stage?: string | null;
  profile_id: string; // nullable in PG schema for backwards compatibility
}

export interface outbound_messages_routing {
  id: string;
  to_number: string;
  from_number?: string | null;
  estimated_segments?: number | null;
  stage: outbound_message_stages;
  decision_stage?: string | null;
  first_from_to_pair_of_day?: boolean | null;
  sending_location_id?: string | null;
  pending_number_request_id?: string | null;
  send_after?: Date | null;
  processed_at?: Date | null;
  original_created_at: Date;
  profile_id: string; // nullable in PG schema for backwards compatibility
}

export interface outbound_messages_telco {
  id: string;
  service_id?: string | null;
  telco_status: telco_status;
  num_segments?: number | null;
  num_media?: number | null;
  cost_in_cents?: number | null;
  extra?: unknown | null;
  original_created_at: Date;
  sent_at?: Date | null;
  profile_id: string;
}

export interface pending_number_request_capacity {
  pending_number_request_id?: string | null;
  commitment_count?: bigint | null;
}

export interface phone_number_requests {
  id: string;
  sending_location_id: string;
  area_code: string;
  created_at?: Date | null;
  phone_number?: string | null;
  fulfilled_at?: Date | null;
  commitment_count?: bigint | null;
  service_order_id?: string | null;
  service?: profile_service_option | null;
  service_10dlc_campaign_id?: string | null;
  service_order_completed_at?: Date | null;
  service_profile_associated_at?: Date | null;
  service_10dlc_campaign_associated_at?: Date | null;
}

export interface phone_numbers {
  phone_number?: string | null;
  created_at?: Date | null;
  sending_location_id?: string | null;
  cordoned_at?: Date | null;
}

export interface previous_mapping_pairings {
  profile_id?: string | null;
  to_number?: string | null;
  from_number?: string | null;
  last_used_at: Date;
  sending_location_id: string;
  cordoned_at?: Date | null;
  invalidated_at?: Date | null;
}

export interface profile_service_configurations {
  id: string;
  twilio_configuration_id?: string | null;
  telnyx_configuration_id?: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface profiles {
  id: string;
  client_id: string;
  sending_account_id: string;
  display_name?: string | null;
  reply_webhook_url: string;
  message_status_webhook_url: string;
  default_purchasing_strategy: number_purchasing_strategy;
  voice_callback_url?: string | null;
  daily_contact_limit: number;
  throughput_interval: string;
  throughput_limit: number;
  service_10dlc_campaign_id?: string | null;
  channel: traffic_channel;
  provisioned: boolean;
  disabled: boolean;
  active?: boolean | null;
  toll_free_use_case_id?: string | null;
  profile_service_configuration_id?: string | null;
}

export interface sending_accounts {
  id: string;
  display_name?: string | null;
  service: profile_service_option;
  twilio_credentials?: any | null;
  telnyx_credentials?: any | null;
  run_cost_backfills?: boolean | null;
  bandwidth_credentials?: any | null;
}

export interface sending_accounts_as_json {
  id?: string | null;
  display_name?: string | null;
  service?: profile_service_option | null;
  twilio_credentials?: unknown | null;
  telnyx_credentials?: unknown | null;
  bandwidth_credentials?: unknown | null;
}

export interface sending_location_capacities {
  id?: string | null;
  profile_id?: string | null;
  reference_name?: string | null;
  center?: string | null;
  sending_account_id?: string | null;
  sending_account_name?: string | null;
  area_code?: string | null;
  capacity?: number | null;
}

export interface sending_locations {
  id: string;
  profile_id: string;
  reference_name: string;
  area_codes?: any[] | null;
  center: string;
  decomissioned_at?: Date | null;
  purchasing_strategy: number_purchasing_strategy;
  state?: string | null;
  location?: { x: number; y: number } | null;
}

export interface telnyx_profile_service_configurations {
  id: string;
  messaging_profile_id?: string | null;
  billing_group_id?: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface toll_free_use_cases {
  id: string;
  client_id: string;
  sending_account_id: string;
  area_code?: string | null;
  phone_number_request_id?: string | null;
  phone_number_id?: string | null;
  stakeholders: string;
  submitted_at?: Date | null;
  approved_at?: Date | null;
  throughput_interval?: string | null;
  throughput_limit?: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface twilio_profile_service_configurations {
  id: string;
  messaging_service_sid?: string | null;
  created_at: Date;
  updated_at: Date;
}

export interface unmatched_delivery_reports {
  message_service_id: string;
  event_type: delivery_report_event;
  generated_at: Date;
  created_at: Date;
  service: string;
  validated: boolean;
  error_codes?: string[] | null;
  extra?: unknown | null;
}

export interface Tables {
  active_previous_mapping_pairings: active_previous_mapping_pairings;
  all_phone_numbers: all_phone_numbers;
  area_code_capacities: area_code_capacities;
  delivery_report_forward_attempts: delivery_report_forward_attempts;
  delivery_reports: delivery_reports;
  fresh_phone_commitments: fresh_phone_commitments;
  inbound_message_forward_attempts: inbound_message_forward_attempts;
  inbound_messages: inbound_messages;
  outbound_messages: outbound_messages;
  outbound_messages_awaiting_from_number: outbound_messages_awaiting_from_number;
  outbound_messages_routing: outbound_messages_routing;
  outbound_messages_telco: outbound_messages_telco;
  pending_number_request_capacity: pending_number_request_capacity;
  phone_number_requests: phone_number_requests;
  phone_numbers: phone_numbers;
  previous_mapping_pairings: previous_mapping_pairings;
  profile_service_configurations: profile_service_configurations;
  profiles: profiles;
  sending_accounts: sending_accounts;
  sending_accounts_as_json: sending_accounts_as_json;
  sending_location_capacities: sending_location_capacities;
  sending_locations: sending_locations;
  telnyx_profile_service_configurations: telnyx_profile_service_configurations;
  toll_free_use_cases: toll_free_use_cases;
  twilio_profile_service_configurations: twilio_profile_service_configurations;
  unmatched_delivery_reports: unmatched_delivery_reports;
}
