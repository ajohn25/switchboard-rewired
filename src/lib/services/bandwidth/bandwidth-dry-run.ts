import type * as Numbers from '@bandwidth/numbers';
import { getCharCount } from '@trt2/gsm-charset-utils';
import crypto from 'crypto';

import { SendingAccount } from '../../types';
import { delay } from '../../utils';
import {
  Associate10dlcCampaignTnOptions,
  PurchaseNumberOptions,
  SellNumberOptions,
  SendMessageOptions,
  SendMessagePayload,
} from '../service';
import {
  BandwidthBaseService,
  PollBandwidthNumberOrderPayload,
} from './bandwidth-base';

// Response times are based on information provided by Bandwidth API team
const MOCK_RTT_SELLNUMBER_MS = 74;
const MOCK_RTT_SENDMESSAGE_MS = 30; // From API team "Unable to track down, but should be fairly immediate"
const MOCK_RTT_ASSOCIATE10DLCCAMPAIGNTN_MS = 100; // API team did not provide
const MOCK_RTT_ATTEMPTBANDWIDTHTNPURCHASE_MS = 34;
const MOCK_RTT_GETAVAILABLENUMBERS_MS = 755;
const MOCK_RTT_POLLBANDWIDTHNUMBERORDER_MS = 30;

// Alias delay function to clarify intent
const simulateNetworkCall = delay;

export class BandwidthDryRunService extends BandwidthBaseService {
  constructor(sendingAccount: SendingAccount) {
    super(sendingAccount);
  }

  public async sellNumber(_options: SellNumberOptions): Promise<void> {
    await simulateNetworkCall(MOCK_RTT_SELLNUMBER_MS);
  }

  public async sendMessage(
    options: SendMessageOptions
  ): Promise<SendMessagePayload> {
    await simulateNetworkCall(MOCK_RTT_SENDMESSAGE_MS);

    const result: SendMessagePayload = {
      numMedia: options.media_urls?.length ?? 0,
      numSegments: getCharCount(options.body).msgCount,
      serviceId: `service-${options.id}`,
      costInCents: null,
    };
    return result;
  }

  public async associate10dlcCampaignTn(
    _options: Associate10dlcCampaignTnOptions
  ): Promise<void> {
    await simulateNetworkCall(MOCK_RTT_ASSOCIATE10DLCCAMPAIGNTN_MS);
  }

  protected async attemptBandwidthTnPurchase(
    attemptNumber: string,
    options: PurchaseNumberOptions
  ): Promise<{ phoneNumber: string; orderId: string }> {
    await simulateNetworkCall(MOCK_RTT_ATTEMPTBANDWIDTHTNPURCHASE_MS);

    const e164Number = `+1${attemptNumber}`;
    const orderId = crypto.randomUUID();
    return { phoneNumber: e164Number, orderId };
  }

  protected async getAvailableBandwidthNumbers(
    areaCode: string,
    quantity: number
  ): Promise<Numbers.AvailableNumbersListResult> {
    await simulateNetworkCall(MOCK_RTT_GETAVAILABLENUMBERS_MS);

    const resultCount = crypto.randomInt(1, quantity);
    const telephoneNumber = [...Array(resultCount)].map(() => {
      const localNumber = [...Array(7)]
        .map(() => crypto.randomInt(0, 10))
        .join('');
      return `+1${areaCode}${localNumber}`;
    });

    return { resultCount, telephoneNumberList: { telephoneNumber } };
  }

  protected async pollBandwidthNumberOrder(
    serviceOrderId: string
  ): Promise<PollBandwidthNumberOrderPayload> {
    await simulateNetworkCall(MOCK_RTT_POLLBANDWIDTHNUMBERORDER_MS);

    const result: PollBandwidthNumberOrderPayload = {
      orderStatus: 'COMPLETE',
      failedQuantity: 0,
    };
    return result;
  }
}

export default BandwidthDryRunService;
