import nock from 'nock';

import { TELNYX_10DLC_API_BASE } from './constants';

export interface TelnyxCreatePhoneNumberCampaignResponseOptions {
  campaignId: string;
  phoneNumber: string;
}

export const mockTelnyxCreatePhoneNumberCampaignResponse = (
  options: TelnyxCreatePhoneNumberCampaignResponseOptions
) => ({
  campaignId: options.campaignId,
  createdAt: new Date().toUTCString(),
  phoneNumber: options.phoneNumber,
  updatedAt: new Date().toUTCString(),
});

export const nockCreatePhoneNumberCampaign = () =>
  nock(TELNYX_10DLC_API_BASE)
    .post(new RegExp('/phone_number_campaigns'))
    .reply(200, (uri, requestBody) => {
      const { phoneNumber, campaignId } = requestBody as any;
      return mockTelnyxCreatePhoneNumberCampaignResponse({
        campaignId,
        phoneNumber,
      });
    });
