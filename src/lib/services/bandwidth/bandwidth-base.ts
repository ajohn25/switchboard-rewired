import type {
  BandwidthCallbackMessage,
  BandwidthMessage,
  MessageRequest,
} from '@bandwidth/messaging';
import type * as Numbers from '@bandwidth/numbers';

import { errToObj, logger } from '../../../logger';
import { crypt } from '../../crypt';
import {
  BadNumberOrderStatusError,
  NoAvailableNumbersError,
} from '../../errors';
import { PostgresErrorCodes } from '../../postgres-errors';
import {
  BandwidthCredentials,
  BandwidthDeliveryReportType,
  DeliveryReport,
  DeliveryReportEvent,
  IncomingMessage,
  SendingAccount,
} from '../../types';
import {
  DlrResolutionInfo,
  DlrResolutionInfoV1,
  EstimateAreaCodeCapacityOptions,
  InboundMessageResponseHandler,
  ParseDeliveryReportOptions,
  ParseDeliveryReportPayload,
  ParseInboundMessageOptions,
  ParseInboundMessagePayload,
  PollNumberOrderOptions,
  PurchaseNumberOptions,
  SendMessageOptions,
  SendMessagePayload,
  SwitchboardClient,
} from '../service';

export const EVENT_TYPE_MAP: Record<
  BandwidthDeliveryReportType,
  DeliveryReportEvent
> = {
  [BandwidthDeliveryReportType.Sending]: DeliveryReportEvent.Sending,
  [BandwidthDeliveryReportType.Delivered]: DeliveryReportEvent.Delivered,
  [BandwidthDeliveryReportType.Failed]: DeliveryReportEvent.DeliveryFailed,
};

export type PollBandwidthNumberOrderPayload = Pick<
  Numbers.OrderGetResult,
  'orderStatus' | 'failedQuantity'
>;

// Max is 5000 (from https://dev.bandwidth.com/docs/numbers/guides/searchingForNumbers/)
const MAX_RESULTS_PER_NUMBERS_SEARCH = 500;

export abstract class BandwidthBaseService extends SwitchboardClient {
  protected credentials: BandwidthCredentials;

  constructor(sendingAccount: SendingAccount) {
    super(sendingAccount);

    const { bandwidth_credentials } = sendingAccount;
    if (bandwidth_credentials === null) {
      throw new Error(
        `Undefined bandwidth credentials for sending account ${sendingAccount.sending_account_id}`
      );
    }
    this.credentials = bandwidth_credentials;
  }

  public async purchaseNumber(options: PurchaseNumberOptions): Promise<void> {
    const { area_code: areaCode } = options;

    const squashAnticipatedError = (err: any) => {
      if (err.code && err.code === PostgresErrorCodes.UniqueViolation) {
        // Move on to the next number if error is a phone number conflict with another purchase request
        return;
      }

      throw err;
    };

    const searchResult = await this.getAvailableBandwidthNumbers(
      areaCode,
      MAX_RESULTS_PER_NUMBERS_SEARCH
    );
    const { telephoneNumber } = searchResult.telephoneNumberList;
    const availableNumbers = Array.isArray(telephoneNumber)
      ? telephoneNumber
      : [telephoneNumber];

    for (const phoneNumber of availableNumbers) {
      // Make sure a different request didn't just claim this number
      try {
        const e164Number = `+1${phoneNumber}`;
        await options.claimNumber(e164Number);
      } catch (err) {
        squashAnticipatedError(err);
        continue;
      }

      // Make sure a different request didn't just buy this number
      if (await options.doesLivePhoneNumberExist(phoneNumber)) {
        continue;
      }

      const result = await this.attemptBandwidthTnPurchase(
        phoneNumber,
        options
      );
      await options.saveResult(result);
      return;
    }

    throw new NoAvailableNumbersError(this._service, areaCode);
  }

  public async estimateAreaCodeCapacity(
    options: EstimateAreaCodeCapacityOptions
  ): Promise<number> {
    const { areaCode } = options;
    const result = await this.getAvailableBandwidthNumbers(
      areaCode,
      MAX_RESULTS_PER_NUMBERS_SEARCH
    );
    return result.resultCount;
  }

  public async sendMessage(
    options: SendMessageOptions
  ): Promise<SendMessagePayload> {
    const { account_id: accountId, application_id: applicationId } =
      this.credentials;

    const tag = `v1|${options.id}|${options.original_created_at}`;

    const body: MessageRequest = {
      applicationId,
      to: [options.to_number],
      from: options.from_number,
      text: options.body,
      tag,
    };

    if (
      options.media_urls &&
      Array.isArray(options.media_urls) &&
      options.media_urls.length > 0
    ) {
      body.media = options.media_urls;
    }

    try {
      const message = await this.sendBandwithMessage(body);

      // Type BandwidthMessage
      const result: SendMessagePayload = {
        numMedia: message.media?.length ?? 0,
        numSegments: message.segmentCount!,
        serviceId: message.id!,
        costInCents: null,
      };
      return result;
    } catch (err) {
      logger.warn('Encountered unexpected Bandwidth error: ', {
        options,
        error: errToObj(err),
      });

      throw err;
    }
  }

  public async pollNumberOrder(options: PollNumberOrderOptions): Promise<void> {
    const { serviceOrderId } = options;
    const result = await this.pollBandwidthNumberOrder(serviceOrderId);
    if (result.orderStatus !== 'COMPLETE' || result.failedQuantity > 0) {
      const status =
        result.orderStatus !== 'COMPLETE'
          ? result.orderStatus
          : `failed count: ${result.failedQuantity}`;
      throw new BadNumberOrderStatusError(
        this._service,
        serviceOrderId,
        status
      );
    }
  }

  public async parseDeliveryReport(
    options: ParseDeliveryReportOptions
  ): Promise<ParseDeliveryReportPayload> {
    const { req } = options;
    const notification: Required<BandwidthCallbackMessage> = req.body[0];
    const { type, message } = notification;
    const { id: messageServiceId } = message;

    const validated =
      req.headers.authorization !== undefined &&
      this.isCallbackAuthenticated(req.headers.authorization);

    const eventType = EVENT_TYPE_MAP[type as BandwidthDeliveryReportType];

    const deliveryReport: DeliveryReport = {
      errorCodes: notification.errorCode ? [notification.errorCode] : null,
      eventType,
      generatedAt: new Date(),
      messageServiceId: messageServiceId!,
      service: this._service,
      validated,
    };

    const dlrResolutionInfo = this.dlrResolutionInfoFromTag(message);

    return { deliveryReport, dlrResolutionInfo };
  }

  public async processInboundMessage(
    options: ParseInboundMessageOptions
  ): Promise<ParseInboundMessagePayload> {
    const { req } = options;
    const validated =
      req.headers.authorization !== undefined &&
      this.isCallbackAuthenticated(req.headers.authorization);

    const { time, to, message: bandwidthMessage } = req.body[0];

    const mediaUrls = bandwidthMessage.media ?? [];

    const message: IncomingMessage = {
      to,
      validated,
      body: bandwidthMessage.text,
      extra: {},
      from: bandwidthMessage.from,
      mediaUrls,
      numMedia: mediaUrls.length,
      numSegments: bandwidthMessage.segmentCount,
      receivedAt: time,
      service: this._service,
      serviceId: bandwidthMessage.id,
    };

    const httpResponseHandler: InboundMessageResponseHandler = (
      messageId,
      res
    ) => {
      res.set('x-created-message-id', messageId);
      res.sendStatus(200);
    };

    return { message, httpResponseHandler };
  }

  public isCallbackAuthenticated(authorization: string) {
    try {
      const encodedAuth = authorization.match(/^Basic (.*)$/)![1];
      const [username, password] = Buffer.from(encodedAuth, 'base64')
        .toString('utf-8')
        .split(':');
      return (
        username === this.credentials.callback_username &&
        password === crypt.decrypt(this.credentials.callback_encrypted_password)
      );
    } catch {
      return false;
    }
  }

  protected dlrResolutionInfoFromTag(
    message: BandwidthMessage
  ): DlrResolutionInfo | undefined {
    const { tag, media, segmentCount } = message;

    if (!tag) return undefined;

    const [version, ...parts] = tag.split('|');

    if (version === 'v1') {
      const [messageId, originalCreatedAt] = parts;
      const info: DlrResolutionInfoV1 = {
        version,
        messageId,
        originalCreatedAt,
        numSegments: segmentCount!,
        numMedia: media?.length ?? 0,
      };
      return info;
    }

    throw new Error('Unrecognized DlrResolutionInfo version');
  }

  protected async sendBandwithMessage(
    body: MessageRequest
  ): Promise<BandwidthMessage> {
    throw new Error('Not implemented for base class!');
  }

  protected async attemptBandwidthTnPurchase(
    attemptNumber: string,
    options: PurchaseNumberOptions
  ): Promise<{
    phoneNumber: string;
    orderId: string;
  }> {
    throw new Error('Not implemented for base class!');
  }

  protected async getAvailableBandwidthNumbers(
    areaCode: string,
    quantity: number
  ): Promise<Numbers.AvailableNumbersListResult> {
    throw new Error('Not implemented for base class!');
  }

  protected async pollBandwidthNumberOrder(
    serviceOrderId: string
  ): Promise<PollBandwidthNumberOrderPayload> {
    throw new Error('Not implemented for base class!');
  }
}
