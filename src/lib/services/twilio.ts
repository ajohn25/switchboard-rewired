import { default as constructor, Twilio } from 'twilio';
import config from '../../config';
import { errToObj, logger } from '../../logger';
import { crypt } from '../crypt';
import { CodedSendMessageError, NoAvailableNumbersError } from '../errors';
import {
  DeliveryReport,
  DeliveryReportEvent,
  IncomingMessage,
  SendingAccount,
  SwitchboardErrorCodes,
  TwilioDeliveryReportRequestBody,
  TwilioDeliveryReportStatus,
  TwilioReplyRequestBody,
} from '../types';
import {
  Associate10dlcCampaignTnOptions,
  EstimateAreaCodeCapacityOptions,
  InboundMessageResponseHandler,
  ParseDeliveryReportOptions,
  ParseDeliveryReportPayload,
  ParseInboundMessageOptions,
  ParseInboundMessagePayload,
  PurchaseNumberOptions,
  SellNumberOptions,
  SendMessageOptions,
  SendMessagePayload,
  SwitchboardClient,
} from './service';

const TWILIO_MAX_VALIDITY_PERIOD = 14400;
const MAX_AREA_CODE_FETCH_COUNT = 500;

export const EVENT_TYPE_MAP: Record<
  TwilioDeliveryReportStatus,
  DeliveryReportEvent
> = {
  [TwilioDeliveryReportStatus.Undelivered]: DeliveryReportEvent.DeliveryFailed,
  [TwilioDeliveryReportStatus.Failed]: DeliveryReportEvent.SendingFailed,
  [TwilioDeliveryReportStatus.Delivered]: DeliveryReportEvent.Delivered,
  [TwilioDeliveryReportStatus.Queued]: DeliveryReportEvent.Queued,
  [TwilioDeliveryReportStatus.Sent]: DeliveryReportEvent.Sent,
};

export class TwilioService extends SwitchboardClient {
  protected authToken: string;
  protected client: Twilio;

  constructor(public sendingAccount: SendingAccount) {
    super(sendingAccount);

    const { twilio_credentials } = sendingAccount;
    if (twilio_credentials === null) {
      throw new Error(
        `Undefined twilio credentials for sending account ${sendingAccount.sending_account_id}`
      );
    }
    const { account_sid, encrypted_auth_token } = twilio_credentials;

    this.authToken = crypt.decrypt(encrypted_auth_token);
    this.client = constructor(account_sid, this.authToken);
  }

  public async sendMessage(
    options: SendMessageOptions
  ): Promise<SendMessagePayload> {
    try {
      const validityPeriod = options.send_before
        ? Math.min(
            Math.floor(
              (new Date(options.send_before).getTime() - new Date().getTime()) /
                1000 // miliseconds -> seconds
            ),
            TWILIO_MAX_VALIDITY_PERIOD
          )
        : undefined;

      const message = await this.client.messages.create({
        validityPeriod,
        body: options.body,
        from: options.from_number,
        mediaUrl: options.media_urls || undefined,
        statusCallback: `${config.baseUrl}/hooks/status/${this._sendingAccount.sending_account_id}`,
        to: options.to_number,
      });

      return {
        // convert the string '-0.0075' -> .75
        costInCents: parseFloat(message.price) * -1 * 100,
        numMedia: parseInt(message.numMedia, 10),
        numSegments: parseInt(message.numSegments, 10),
        serviceId: message.sid,
      };
    } catch (err: any) {
      // Throw the error if it was not a coded Twilio response (e.g. network timeout)
      if (!err.code) throw err;

      if (err.code === 21610) {
        throw new CodedSendMessageError(SwitchboardErrorCodes.Blacklist);
      } else if (err.code === 63026) {
        throw new CodedSendMessageError(SwitchboardErrorCodes.SpamContent);
      } else if (err.code === 21211) {
        throw new CodedSendMessageError(
          SwitchboardErrorCodes.InvalidDestinationNumber
        );
      }

      logger.warn('Encountered unexpected Twilio error: ', {
        options,
        error: errToObj(err),
      });

      throw err;
    }
  }

  public async purchaseNumber(options: PurchaseNumberOptions): Promise<void> {
    const {
      sending_account_id: sendingAccountId,
      area_code: areaCode,
      voice_callback_url: voiceCallbackUrl,
    } = options;
    // Twilio's API does not allow specifying capabilities for this method
    const { sid, phoneNumber } = await this.client.incomingPhoneNumbers
      .create({
        areaCode,
        smsMethod: 'POST',
        smsUrl: `${config.baseUrl}/hooks/reply/${sendingAccountId}`,
        statusCallback: `${config.baseUrl}/hooks/status/${sendingAccountId}`,
        statusCallbackMethod: 'POST',
        voiceUrl: voiceCallbackUrl ?? undefined,
      })
      .catch((err: any) => {
        logger.error('Error purchasing Twilio phone number: ', errToObj(err));
        // Treat all Twilio errors as no-numbers-available
        throw new NoAvailableNumbersError(this._service, areaCode);
      });

    await options.saveResult({ phoneNumber, orderId: sid });
  }

  public async estimateAreaCodeCapacity(
    options: EstimateAreaCodeCapacityOptions
  ): Promise<number> {
    const availablePhoneNumbers = await this.client
      .availablePhoneNumbers('US')
      .local.list({
        areaCode: parseInt(options.areaCode, 10),
        limit: MAX_AREA_CODE_FETCH_COUNT,
        smsEnabled: true,
      });
    const capacity = availablePhoneNumbers.length;
    return capacity;
  }

  public async sellNumber(options: SellNumberOptions): Promise<void> {
    const phoneNumber = await this.fetchTn(options.phone_number);
    await phoneNumber.remove();
  }

  public async parseDeliveryReport(
    options: ParseDeliveryReportOptions
  ): Promise<ParseDeliveryReportPayload> {
    const { req } = options;
    const validated = constructor.validateExpressRequest(req, this.authToken);
    // TODO – reject bad incoming delivery reports and figure out good test solution

    const body: TwilioDeliveryReportRequestBody = req.body;

    const status = EVENT_TYPE_MAP[body.MessageStatus];

    const deliveryReport: DeliveryReport = {
      errorCodes: body.ErrorCode ? [body.ErrorCode] : null,
      eventType: status,
      generatedAt: new Date(),
      messageServiceId: body.SmsSid,
      service: this._service,
      validated,
    };

    return { deliveryReport };
  }

  public async processInboundMessage(
    options: ParseInboundMessageOptions
  ): Promise<ParseInboundMessagePayload> {
    const { req } = options;

    const isValid = constructor.validateExpressRequest(req, this.authToken);
    // TODO – reject bad incoming messages and figure out good test solution

    const body: TwilioReplyRequestBody = req.body;
    const message: IncomingMessage = {
      body: body.Body,
      extra: {},
      from: body.From,
      mediaUrls: Object.keys(body)
        .filter((key) => key.includes('MediaUrl'))
        .sort()
        .map((mediaUrlKey) => body[mediaUrlKey]),
      numMedia: parseInt(body.NumMedia, 10),
      numSegments: parseInt(body.NumSegments, 10),
      receivedAt: new Date().toISOString(),
      service: this._service,
      serviceId: body.SmsSid,
      to: body.To,
      validated: isValid,
    };

    const httpResponseHandler: InboundMessageResponseHandler = (
      messageId,
      res
    ) => {
      const twimlResponse = new constructor.twiml.MessagingResponse();
      res.writeHead(200, {
        'Content-Type': 'text/xml',
        'x-created-message-id': messageId,
      });
      res.end(twimlResponse.toString());
    };

    return { message, httpResponseHandler };
  }

  public async associate10dlcCampaignTn(
    options: Associate10dlcCampaignTnOptions
  ): Promise<void> {
    const { phoneNumber, campaignId } = options;
    const phoneNumberSid = await this.fetchTn(phoneNumber).then((tn) => tn.sid);
    await this.client.messaging
      .services(campaignId)
      .phoneNumbers.create({ phoneNumberSid });
  }

  protected async fetchTn(phoneNumber: string) {
    const matchingNumbers = await this.client.incomingPhoneNumbers.list({
      phoneNumber,
    });

    const foundNumber = matchingNumbers[0];

    if (!foundNumber) {
      throw new Error(
        `No phone number matching ${phoneNumber} was found in this Twilio account`
      );
    }

    return foundNumber;
  }
}
