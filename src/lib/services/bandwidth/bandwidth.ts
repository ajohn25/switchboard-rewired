import {
  ApiController as MessagingController,
  BandwidthMessage,
  Client as MessagingClient,
  MessageRequest,
} from '@bandwidth/messaging';
import * as Numbers from '@bandwidth/numbers';
import superagent from 'superagent';
import xml2js from 'xml2js';

import { crypt } from '../../crypt';
import { BadNumberOrderStatusError } from '../../errors';
import { SendingAccount } from '../../types';
import {
  Associate10dlcCampaignTnOptions,
  PollNumberOrderOptions,
  PurchaseNumberOptions,
  SellNumberOptions,
} from '../service';
import {
  BandwidthBaseService,
  PollBandwidthNumberOrderPayload,
} from './bandwidth-base';

const BANDWIDTH_API_URL = 'https://dashboard.bandwidth.com';

export class BandwidthService extends BandwidthBaseService {
  protected numbersClient: Numbers.Client;
  protected messagingClient: MessagingClient;
  protected messagingController: MessagingController;

  constructor(sendingAccount: SendingAccount) {
    super(sendingAccount);

    const { username, encrypted_password, account_id } = this.credentials;
    const password = crypt.decrypt(encrypted_password);
    this.numbersClient = new Numbers.Client(account_id, username, password);
    this.messagingClient = new MessagingClient({
      basicAuthUserName: username,
      basicAuthPassword: password,
    });
    this.messagingController = new MessagingController(this.messagingClient);
  }

  public async associate10dlcCampaignTn(
    options: Associate10dlcCampaignTnOptions
  ): Promise<void> {
    const { account_id: accountId } = this.credentials;
    const body = new xml2js.Builder().buildObject({
      TnOptionOrder: {
        TnOptionGroups: {
          TnOptionGroup: {
            Sms: 'on',
            A2pSettings: {
              Action: 'asSpecified',
              CampaignId: options.campaignId,
            },
            TelephoneNumbers: [
              { TelephoneNumber: options.phoneNumber.replace('+1', '') },
            ],
          },
        },
      },
    });

    const password = crypt.decrypt(this.credentials.encrypted_password);
    const result = await superagent
      .post(`${BANDWIDTH_API_URL}/api/accounts/${accountId}/tnoptions`)
      .auth(this.credentials.username, password)
      .set('Content-Type', 'application/xml')
      .send(body);

    if (!result.ok) {
      throw new Error(
        `Error creating Bandwidth TN options order: ${result.body.toString()}`
      );
    }
  }

  public async sellNumber(options: SellNumberOptions): Promise<void> {
    const { id: phoneNumberId, phone_number } = options;
    await Numbers.Disconnect.createAsync(this.numbersClient, phoneNumberId, [
      phone_number,
    ]);
  }

  protected async sendBandwithMessage(
    body: MessageRequest
  ): Promise<BandwidthMessage> {
    const { account_id: accountId } = this.credentials;
    const { result: message } = await this.messagingController.createMessage(
      accountId,
      body
    );
    return message;
  }

  protected async attemptBandwidthTnPurchase(
    attemptNumber: string,
    options: PurchaseNumberOptions
  ): Promise<{
    phoneNumber: string;
    orderId: string;
  }> {
    const { site_id: siteId, location_id: peerId } = this.credentials;
    const {
      id: requestId,
      area_code: areaCode,
      sending_location_id: sendingLocationId,
    } = options;

    const orderPayload: Numbers.CreateOrderType = {
      customerOrderId: requestId,
      name: `1x (${areaCode}) for SL: ${sendingLocationId}`,
      siteId,
      peerId,
      existingTelephoneNumberOrderType: {
        telephoneNumberList: [{ telephoneNumber: attemptNumber }],
      },
    };

    const result = await Numbers.Order.createAsync(
      this.numbersClient,
      orderPayload
    );

    const e164Number = `+1${attemptNumber}`;
    return { phoneNumber: e164Number, orderId: result.order.id };
  }

  protected async getAvailableBandwidthNumbers(
    areaCode: string,
    quantity: number
  ): Promise<Numbers.AvailableNumbersListResult> {
    const result = await Numbers.AvailableNumbers.listAsync(
      this.numbersClient,
      { areaCode, quantity }
    );

    const { resultCount = 0, telephoneNumberList = { telephoneNumber: [] } } =
      result;
    return { resultCount, telephoneNumberList };
  }

  protected async pollBandwidthNumberOrder(
    serviceOrderId: string
  ): Promise<PollBandwidthNumberOrderPayload> {
    const result = await Numbers.Order.getAsync(
      this.numbersClient,
      serviceOrderId
    );
    return result;
  }
}

export default BandwidthService;
