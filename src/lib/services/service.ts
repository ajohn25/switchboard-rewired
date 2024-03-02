import type { Request, Response } from 'express';

import { UnimplementedTelcoMethodError } from '../errors';
import type {
  DeliveryReport,
  IncomingMessage,
  SendingAccount,
  Service,
  TenDlcMnoMetadataRecord,
} from '../types';

export interface ProfileOptions {
  profile_id: string;
  service_profile_id: string | null;
  voice_callback_url: string | null;
  tendlc_campaign_id: string | null;
}

export interface PurchaseNumberCallbackPayload {
  phoneNumber: string;
  orderId?: string;
}

export interface PurchaseNumberOptions extends ProfileOptions {
  area_code: string;
  id: string;
  sending_account_id: string;
  sending_location_id: string;
  claimNumber: (phoneNumber: string) => Promise<void> | void;
  saveResult: (payload: PurchaseNumberCallbackPayload) => Promise<void>;
  doesLivePhoneNumberExist: (phoneNumber: string) => Promise<boolean>;
}

export interface EstimateAreaCodeCapacityOptions {
  areaCode: string;
}

export interface SellNumberOptions {
  id: string;
  phone_number: string;
}

export interface SendMessageOptions {
  body: string;
  id: string;
  original_created_at: string;
  sending_location_id: string;
  profile_id: string;
  to_number: string;
  from_number: string;
  media_urls: string[] | null;
  send_before: string | null;
}

export interface SendMessagePayload {
  serviceId: string;
  numSegments: number;
  numMedia: number;
  costInCents: number | null;
  extra?: any;
}

export interface AssociateServiceProfileOptions {
  phoneNumber: string;
  serviceProfileId: string;
}

export interface Associate10dlcCampaignTnOptions {
  phoneNumber: string;
  campaignId: string;
}

export interface PollNumberOrderOptions {
  serviceOrderId: string;
}

export interface ParseDeliveryReportOptions {
  req: Request;
}

export interface DlrResolutionInfoV1 {
  version: 'v1';
  messageId: string;
  originalCreatedAt: string;
  numSegments: number;
  numMedia: number;
}

// Leave open the possibility of future versions
export type DlrResolutionInfo = DlrResolutionInfoV1;

export interface ParseDeliveryReportPayload {
  deliveryReport: DeliveryReport;
  dlrResolutionInfo?: DlrResolutionInfo;
}

export interface ParseInboundMessageOptions {
  req: Request;
}

export type InboundMessageResponseHandler = (
  messageId: string,
  res: Response
) => Promise<void> | void;

export interface ParseInboundMessagePayload {
  message: IncomingMessage;
  httpResponseHandler: InboundMessageResponseHandler;
}

export interface GetMnoMetadataOptions {
  campaignId: string;
}

export type GetMnoMetadataPayload = Record<
  string,
  Omit<
    TenDlcMnoMetadataRecord,
    'id' | 'campaign_id' | 'created_at' | 'updated_at'
  >
>;

export interface TelcoMethods {
  purchaseNumber(options: PurchaseNumberOptions): Promise<void>;

  estimateAreaCodeCapacity(
    options: EstimateAreaCodeCapacityOptions
  ): Promise<number>;

  sellNumber(options: SellNumberOptions): Promise<void>;

  sendMessage(options: SendMessageOptions): Promise<SendMessagePayload>;

  associateServiceProfile(
    options: AssociateServiceProfileOptions
  ): Promise<string>;

  associate10dlcCampaignTn(
    options: Associate10dlcCampaignTnOptions
  ): Promise<void>;

  pollNumberOrder(options: PollNumberOrderOptions): Promise<void>;

  parseDeliveryReport(
    options: ParseDeliveryReportOptions
  ): Promise<ParseDeliveryReportPayload>;

  processInboundMessage(
    options: ParseInboundMessageOptions
  ): Promise<ParseInboundMessagePayload>;

  getMnoMetadata(
    options: GetMnoMetadataOptions
  ): Promise<GetMnoMetadataPayload>;
}

export abstract class SwitchboardClient implements TelcoMethods {
  protected _sendingAccount: SendingAccount;
  protected _service: Service;

  constructor(public sendingAccount: SendingAccount) {
    this._sendingAccount = sendingAccount;
    this._service = sendingAccount.service;
  }

  public purchaseNumber(options: PurchaseNumberOptions): Promise<void> {
    throw new UnimplementedTelcoMethodError(this._service, 'purchaseNumber');
  }

  public estimateAreaCodeCapacity(
    options: EstimateAreaCodeCapacityOptions
  ): Promise<number> {
    throw new UnimplementedTelcoMethodError(
      this._service,
      'estimateAreaCodeCapacity'
    );
  }

  public sellNumber(options: SellNumberOptions): Promise<void> {
    throw new UnimplementedTelcoMethodError(this._service, 'sellNumber');
  }

  public sendMessage(options: SendMessageOptions): Promise<SendMessagePayload> {
    throw new UnimplementedTelcoMethodError(this._service, 'sendMessage');
  }

  public associateServiceProfile(
    options: AssociateServiceProfileOptions
  ): Promise<string> {
    throw new UnimplementedTelcoMethodError(
      this._service,
      'associateServiceProfile'
    );
  }

  public associate10dlcCampaignTn(
    options: Associate10dlcCampaignTnOptions
  ): Promise<void> {
    throw new UnimplementedTelcoMethodError(
      this._service,
      'associate10dlcCampaignTn'
    );
  }

  public pollNumberOrder(options: PollNumberOrderOptions): Promise<void> {
    throw new UnimplementedTelcoMethodError(this._service, 'pollNumberOrder');
  }

  public parseDeliveryReport(
    options: ParseDeliveryReportOptions
  ): Promise<ParseDeliveryReportPayload> {
    throw new UnimplementedTelcoMethodError(
      this._service,
      'parseDeliveryReport'
    );
  }

  public processInboundMessage(
    options: ParseInboundMessageOptions
  ): Promise<ParseInboundMessagePayload> {
    throw new UnimplementedTelcoMethodError(
      this._service,
      'parseInboundMessage'
    );
  }

  public getMnoMetadata(
    options: GetMnoMetadataOptions
  ): Promise<GetMnoMetadataPayload> {
    throw new UnimplementedTelcoMethodError(this._service, 'getMnoMetadata');
  }
}
