import nock from 'nock';

import { TELNYX_V2_API_URL } from './constants';

export interface MockSetMessagingProfileOptions {
  phoneNumber: string;
  serviceProfileId: string;
}

export const mockTelnyxUpdateNumberResponse = (
  options: MockSetMessagingProfileOptions
) => ({
  data: {
    country_code: 'US',
    created_at: '2019-01-23T18:10:02.574Z',
    eligible_messaging_products: ['A2P'],
    features: {
      mms: null,
      sms: {
        domestic_two_way: true,
        international_inbound: true,
        international_outbound: true,
      },
    },
    health: {
      inbound_outbound_ratio: 0.43,
      message_count: 122,
      spam_ratio: 0.06,
      success_ratio: 0.94,
    },
    id: options.phoneNumber,
    messaging_product: 'A2P',
    messaging_profile_id: options.serviceProfileId,
    phone_number: options.phoneNumber,
    record_type: 'messaging_phone_number',
    traffic_type: 'A2P',
    type: 'toll-free',
    updated_at: '2018-01-01T00:00:00.000000Z',
  },
});

export const nockSetMessagingProfile = () => {
  nock(TELNYX_V2_API_URL)
    .patch(new RegExp('/messaging_phone_numbers/.*'))
    .reply(200, (uri, body) => {
      const phoneNumber = uri.match(
        new RegExp('/messaging_phone_numbers/(.*)')
      )![1];
      const { messaging_profile_id: serviceProfileId } = body as any;
      return mockTelnyxUpdateNumberResponse({ phoneNumber, serviceProfileId });
    });
};
