import { Pool, PoolClient } from 'pg';
import { z } from 'zod';

export enum Service {
  Telnyx = 'telnyx',
  Twilio = 'twilio',
  Bandwidth = 'bandwidth',
  BandwidthDryRun = 'bandwidth-dry-run',
  Tcr = 'tcr',
}

// tslint:disable-next-line: variable-name
export const ServiceEnum = z.nativeEnum(Service);

export enum TrafficChannel {
  GreyRoute = 'grey-route',
  TollFree = 'toll-free',
  TenDlc = '10dlc',
}

export enum SendingLocationPurchasingStrategy {
  ExactAreaCodes = 'exact-area-codes',
  SameStateByDistance = 'same-state-by-distance',
}

export interface ClientRecord {
  id: string;
  name: string;
  access_token: string;
  created_at: string;
}

// tslint:disable-next-line: variable-name
export const TwilioCredentialsSchema = z
  .object({
    account_sid: z.string(),
    encrypted_auth_token: z.string(),
  })
  .required();

export type TwilioCredentials = z.infer<typeof TwilioCredentialsSchema>;

// tslint:disable-next-line: variable-name
export const TelnyxCredentialsSchema = z
  .object({
    encrypted_api_key: z.string(),
    public_key: z.string(),
  })
  .required();

export type TelnyxCredentials = z.infer<typeof TelnyxCredentialsSchema>;

// tslint:disable-next-line: variable-name
export const BandwidthCredentialsSchema = z
  .object({
    account_id: z.string(),
    username: z.string(),
    encrypted_password: z.string(),
    site_id: z.string(),
    location_id: z.string(),
    application_id: z.string(),
    callback_username: z.string(),
    callback_encrypted_password: z.string(),
  })
  .required();

export type BandwidthCredentials = z.infer<typeof BandwidthCredentialsSchema>;

// tslint:disable-next-line: variable-name
export const TcrCredentialsSchema = z
  .object({
    api_key_label: z.string(),
    api_key: z.string(),
    encrypted_secret: z.string(),
  })
  .required();

export type TcrCredentials = z.infer<typeof TcrCredentialsSchema>;

// tslint:disable-next-line: variable-name
export const SendingAccountRecordSchema = z
  .object({
    id: z.string().uuid(),
    display_name: z.string().nullable(),
    service: ServiceEnum,
    twilio_credentials: TwilioCredentialsSchema.nullable(),
    telnyx_credentials: TelnyxCredentialsSchema.nullable(),
    bandwidth_credentials: BandwidthCredentialsSchema.nullable(),
    tcr_credentials: TcrCredentialsSchema.nullable(),
    run_cost_backfills: z.boolean().nullable(),
  })
  .required();

export type SendingAccountRecord = z.infer<typeof SendingAccountRecordSchema>;

export interface TollFreeUseCaseRecord {
  id: string;
  client_id: string;
  sending_account_id: string;
  area_code: string | null;
  phone_number_request_id: string;
  phone_number_id: string | null;
  stakeholders: string;
  submitted_at: string | null;
  approved_at: string | null;
  throughput_interval: string | null;
  throughput_limit: string | null;
  created_at: string;
  updated_at: string;
}

// tslint:disable-next-line: variable-name
export const TrafficChannelType = z.nativeEnum(TrafficChannel);

// tslint:disable-next-line: variable-name
export const SendingLocationPurchasingStrategyType = z.nativeEnum(
  SendingLocationPurchasingStrategy
);

// tslint:disable-next-line: variable-name
export const ProfileRecordSchema = z
  .object({
    id: z.string().uuid(),
    client_id: z.string().uuid(),
    sending_account_id: z.string().uuid(),
    display_name: z.string().nullable(),
    active: z.boolean(),
    provisioned: z.boolean(),
    channel: TrafficChannelType,
    reply_webhook_url: z.string().url(),
    message_status_webhook_url: z.string().url(),
    default_purchasing_strategy: SendingLocationPurchasingStrategyType,
    voice_callback_url: z.string().url().nullable(),
    daily_contact_limit: z.number().nullable(),
    throughput_interval: z.string().nullable(),
    throughput_limit: z.number().int().nullable(),
    profile_service_configuration_id: z.string().uuid().nullable(),
    toll_free_use_case_id: z.string().uuid().nullable(),
    tendlc_campaign_id: z.string().uuid().nullable(),
  })
  .required();

export type ProfileRecord = z.infer<typeof ProfileRecordSchema>;

export interface ProfileServiceConfigurationRecord {
  id: string;
  twilio_configuration_id: string | null;
  telnyx_configuration_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface TwilioProfileServiceConfiguration {
  id: string;
  messaging_service_sid: string | null;
  created_at: string;
  updated_at: string;
}

export interface TelnyxProfileServiceConfiguration {
  id: string;
  messaging_profile_id: string | null;
  billing_group_id: string | null;
  created_at: string;
  updated_at: string;
}

// tslint:disable-next-line variable-name
export const SendingLocationRecordSchema = z.object({
  id: z.string().uuid(),
  profile_id: z.string().uuid(),
  reference_name: z.string(),
  area_codes: z.array(z.string()),
  center: z.string(),
  decomissioned_at: z.string().nullable(),
  purchasing_strategy: SendingLocationPurchasingStrategyType,
  state: z.string().nullable(),
  location: z.any().nullable(),
});

export type SendingLocationRecord = z.infer<typeof SendingLocationRecordSchema>;

export interface SendingAccount {
  service: Service;
  sending_account_id: string;
  twilio_credentials: TwilioCredentials | null;
  telnyx_credentials: TelnyxCredentials | null;
  bandwidth_credentials: BandwidthCredentials | null;
  tcr_credentials: TcrCredentials | null;
}

export interface SendingAccountWithProfile extends SendingAccount {
  profile_id: string;
  voice_callback_url: string;
  tendlc_campaign_id: string | null;
}

export interface ProfileInfo {
  profile_id: string;
  sending_location_id: string;
  encrypted_client_access_token: string;
  reply_webhook_url: string;
  message_status_webhook_url: string;
}

export interface TelnyxReplyRequestBody {
  data: {
    payload: {
      from: {
        phone_number: string;
        carrier: string;
        line_type: string;
        status: string;
      };
      id: string;
      // tslint:disable-next-line: array-type
      media: {
        content_type: string;
        url: string;
        hash_sha256: string;
        size: number;
      }[];
      parts: number;
      received_at: string;
      text: string;
      to: string;
      [other: string]: any;
    };
    [other: string]: any;
  };
  meta: any;
}

export interface TwilioReplyRequestBody {
  NumSegments: string;
  From: string;
  To: string;
  SmsSid: string;
  Body: string;
  NumMedia: string;
  MediaUrl0?: string;
  MediaUrl1?: string;
  MediaUrl2?: string;
  MediaUrl3?: string;
  MediaUrl4?: string;
  MediaUrl5?: string;
  [other: string]: any;
}

export interface TwilioNumberPurchaseRequestBody {
  account_sid: string;
  address_requirements: string;
  address_sid: string;
  api_version: string;
  beta: boolean;
  capabilities: { [key: string]: boolean };
  date_created: string;
  date_updated: string;
  emergency_address_sid: string;
  emergency_status: string;
  friendly_name: string;
  identity_sid: string;
  origin: string;
  phone_number: string;
  sid: string;
  sms_application_sid: string | null;
  sms_fallback_method: string;
  sms_fallback_url: string;
  sms_method: string;
  sms_url: string;
  status_callback: string;
  status_callback_method: string;
  trunk_sid: string | null;
  uri: string;
  voice_application_sid: string | null;
  voice_caller_id_lookup: boolean;
  voice_fallback_method: string;
  voice_fallback_url: string | null;
  voice_method: string;
  voice_url: string | null;
  [other: string]: any;
}

export interface TwilioPagination {
  end: number;
  first_page_uri: string;
  last_page_uri: string;
  next_page_uri: string | null;
  num_pages: number;
  page: number;
  page_size: number;
  previous_page_uri: string;
  start: number;
  total: number;
  uri: string;
}

export interface TwilioAvailablePhoneNumber {
  address_requirements: string;
  beta: boolean;
  capabilities: {
    mms: boolean;
    sms: boolean;
    voice: boolean;
  };
  friendly_name: string;
  iso_country: string;
  lata: string;
  latitude: string;
  locality: string;
  longitude: string;
  phone_number: string;
  postal_code: string;
  rate_center: string;
  region: string;
}

export interface TwilioGetNumbersResponse extends TwilioPagination {
  available_phone_numbers: TwilioAvailablePhoneNumber[];
}

export interface TelnyxRegionInformation {
  region_type: string;
  region_name: string;
}

export interface TelnyxCostInformation {
  upfront_cost: string;
  monthly_cost: string;
  currency: string;
}

export interface TelnyxFeature {
  name: string;
}

export type TelnyxPhoneNumberStatus =
  | 'purchase_pending'
  | 'purchase_failed'
  | 'port_pending'
  | 'active'
  | 'deleted'
  | 'port_failed'
  | 'emergency_only'
  | 'ported_out'
  | 'port_out_pending';

export interface TelnyxPhoneNumber {
  best_effort: boolean;
  cost_information: TelnyxCostInformation;
  features: TelnyxFeature[];
  phone_number: string;
  record_type: string;
  region_information: TelnyxRegionInformation[];
  reservable: boolean;
  vanity_format: string | null;
}

export interface TelnyxNumbersPaginationMeta {
  best_effort_results: number;
  total_results: number;
}

export interface TelnyxSearchNumbersResponse {
  data: TelnyxPhoneNumber[];
  metadata: TelnyxNumbersPaginationMeta;
}

export interface NumberOrderPhoneNumber {
  id: string;
  phone_number: string;
  record_type: string;
  regulatory_requirements: any[];
  requirements_met: boolean;
  status: string;
}

export interface TelnyxOrder {
  connection_id: string;
  created_at: string;
  customer_reference: string;
  id: string;
  messaging_profile_id: string | null;
  phone_numbers: NumberOrderPhoneNumber[];
  phone_numbers_count: number;
  record_type: string;
  requirements_met: boolean;
  status: string;
  updated_at: string;
}

export interface TelnyxOrderPaginationMeta {
  next_page_token: string;
  page_number: number;
  page_size: number;
  total_pages: number;
  total_results: number;
}

// Response for both creating and fetching single
export interface TelnyxOrderResponse {
  data: TelnyxOrder;
}

export interface TelnyxMultiOrderResponse {
  data: TelnyxOrder[];
  meta: TelnyxOrderPaginationMeta;
}

export interface IncomingMessage {
  from: string;
  to: string;
  body: string;
  serviceId: string;
  service: string;
  numSegments: number;
  numMedia: number;
  receivedAt: string;
  mediaUrls: string[];
  extra: any;
  validated: boolean;
}

export enum TwilioDeliveryReportStatus {
  Undelivered = 'undelivered',
  Failed = 'failed',
  Queued = 'queued',
  Sent = 'sent',
  Delivered = 'delivered',
}

export enum BandwidthDeliveryReportType {
  Sending = 'message-sending',
  Delivered = 'message-delivered',
  Failed = 'message-failed',
}

export interface TwilioDeliveryReportRequestBody {
  ErrorCode?: string;
  SmsSid: string;
  SmsStatus: TwilioDeliveryReportStatus;
  MessageStatus: TwilioDeliveryReportStatus;
}

export type BandwidthDeliveryReportRequestBody = [
  {
    type: BandwidthDeliveryReportType;
    time: string;
    description: string;
    to: string;
    errorCode: number;
    message: {
      id: string;
      time: string;
      to: string[];
      from: string;
      text: string;
      applicationId: string;
      media: string[];
      owner: string;
      direction: 'out';
      segmentCount: number;
    };
  }
];

/* 
  {"ErrorCode":"30003","SmsSid":"SMf2459704aada465daf8c50723f8e587e","SmsStatus":"undelivered","MessageStatus":"undelivered","To":"+17148131698","MessagingServiceSid":"MGf5d6aa41a9c9f4606c4cf39a117d7597","MessageSid":"SMf2459704aada465daf8c50723f8e587e","AccountSid":"AC8f2f0df95555ddce28fa99adf7cd1c68","From":"+15754087028","ApiVersion":"2010-04-01"}
*/

export enum DeliveryReportEvent {
  Queued = 'queued',
  Sending = 'sending',
  Sent = 'sent',
  Delivered = 'delivered',
  SendingFailed = 'sending_failed',
  DeliveryFailed = 'delivery_failed',
  DeliveryUnconfirmed = 'delivery_unconfirmed',
}

// tslint:disable-next-line variable-name
export const DeliveryReportEventSchema = z.nativeEnum(DeliveryReportEvent);

// tslint:disable-next-line variable-name
export const TelnyxToSchema = z.object({
  status: DeliveryReportEventSchema,
  address: z.string().optional(),
});

export type TelnyxTo = z.infer<typeof TelnyxToSchema>;

interface TelnyxError {
  code: string;
  title: string;
  detail: string;
}

// tslint:disable-next-line variable-name
export const TelnyxCurrencySchema = z.object({
  amount: z.string().nullable(), // For example, "0.0025"; can be null for `sending_failed` event
  currency: z.string().nullable(),
});

export type TelnyxCurrency = z.infer<typeof TelnyxCurrencySchema>;

export interface TelnyxDeliveryReportRequestBody {
  data: {
    payload: {
      completed_at: string;
      to: TelnyxTo[];
      errors?: TelnyxError[];
      carrier: string;
      line_type: string;
      id: string;
      cost: TelnyxCurrency | null;
    };
  };
}

// tslint:disable-next-line variable-name
export const DeliveryReportExtraSchema = z.object({
  num_segments: z.number().int().optional(),
  num_media: z.number().int().optional(),
  cost: TelnyxCurrencySchema.nullable().optional(),
  to: z.array(TelnyxToSchema).optional(),
});

export type DeliveryReportExtra = z.infer<typeof DeliveryReportExtraSchema>;

export interface DeliveryReport {
  messageServiceId: string;
  eventType: DeliveryReportEvent;
  service: Service;
  errorCodes: string[] | null;
  generatedAt: Date;
  extra?: DeliveryReportExtra | null;
  costInCents?: number | null;
  validated: boolean;
}

export enum SwitchboardErrorCodes {
  Blacklist = '21610',
  SpamContent = '63026',
  InvalidDestinationNumber = '21211',
  CouldNotSendInTime = '30001',
}

export interface LrnUsageRollupRow {
  id: string;
  client_id: string;
  created_at: string;
  period_start: string;
  period_end: string;
  stripe_usage_record_id: string | null;
  lrn: number;
}

export interface MessagingUsageRollupRow {
  id: string;
  profile_id: string;
  created_at: string;
  period_start: string;
  period_end: string;
  stripe_usage_record_id: string | null;
  outbound_sms_messages: number;
  outbound_sms_segments: number;
  outbound_mms_messages: number;
  outbound_mms_segments: number;
  inbound_sms_messages: number;
  inbound_sms_segments: number;
  inbound_mms_messages: number;
  inbound_mms_segments: number;
}

export enum AssembleJobStatus {
  Running = 'running',
  WaitingToRun = 'waiting to run',
  WaitingToRetry = 'waiting to retry',
  Failed = 'failed',
}

export interface AssembleJobRecord {
  id: number;
  queue_name: string;
  payload: { [key: string]: any };
  run_at: string | null;
  status: AssembleJobStatus;
  attempts: number;
  max_attempts: number;
  errors: string[] | null;
  ran_at: string | null;
  created_at: string;
}

// tslint:disable-next-line: variable-name
export const PhoneNumberRequestRecordSchema = z
  .object({
    id: z.string().uuid(),
    sending_location_id: z.string().uuid(),
    area_code: z.string(),
    created_at: z.string(),
    phone_number: z.string().nullable(),
    fulfilled_at: z.string().nullable(),
    commitment_count: z.number().int(),
    service_order_id: z.string().uuid().nullable(),
    service: ServiceEnum,
    tendlc_campaign_id: z.string().uuid().nullable(),
    service_order_completed_at: z.string().nullable(),
    service_profile_associated_at: z.string().nullable(),
    service_10dlc_campaign_associated_at: z.string().nullable(),
  })
  .required();

export type PhoneNumberRequestRecord = z.infer<
  typeof PhoneNumberRequestRecordSchema
>;

export interface FullPhoneNumberRecord {
  id: string;
  phone_number: string;
  sending_location_id: string;
  created_at: string;
  cordoned_at: string | null;
  released_at: string | null;
  sold_at: string | null;
}

export type PhoneNumberRecord = Pick<
  FullPhoneNumberRecord,
  'phone_number' | 'sending_location_id' | 'created_at' | 'cordoned_at'
>;

export interface TenDlcCampaignRecord {
  id: string;
  tcr_account_id: string | null;
  tcr_campaign_id: string | null;
  registrar_account_id: string | null;
  registrar_campaign_id: string | null;
  created_at: string;
  updated_at: string;
}

export interface TenDlcMnoMetadataRecord {
  id: string;
  campaign_id: string;
  mno_id: string;
  mno: string;
  qualify: boolean;
  tpm: number;
  brand_tier: string;
  msg_class: string;
  mno_review: boolean;
  mno_support: boolean;
  min_msg_samples: number;
  req_subscriber_help: boolean;
  req_subscriber_optin: boolean;
  req_subscriber_optout: boolean;
  no_embedded_phone: boolean;
  no_embedded_link: boolean;
  extra: string;
  created_at: string;
  updated_at: string;
}

export type WrappableTask = (
  client: PoolClient,
  payload: unknown
) => Promise<void>;
