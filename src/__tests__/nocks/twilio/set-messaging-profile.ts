import faker from 'faker';
import nock from 'nock';

import { parseUrlEncodedBody } from '../utils';
import { TWILIO_MESSAGING_API_BASE } from './constants';

export interface MockSetMessagingProfileOptions {
  phoneSid: string;
  phoneNumber: string;
  serviceProfileId: string;
}

export const mockTwilioUpdateNumberResponse = (
  options: MockSetMessagingProfileOptions
) => ({
  account_sid: 'ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
  capabilities: [],
  country_code: 'US',
  date_created: '2015-07-30T20:12:31Z',
  date_updated: '2015-07-30T20:12:33Z',
  phone_number: options.phoneNumber,
  service_sid: options.serviceProfileId,
  sid: options.phoneSid,
  url: `https://messaging.twilio.com/v1/Services/${options.serviceProfileId}/PhoneNumbers/${options.phoneSid}`,
});

interface NockOptions {
  phoneNumber?: string;
}

export const nockSetMessagingProfile = (options?: NockOptions) => {
  nock(TWILIO_MESSAGING_API_BASE)
    .post(new RegExp('/Services/.*/PhoneNumbers'))
    .reply((uri, requestBody) => {
      const bodyFields = parseUrlEncodedBody(requestBody);
      const serviceProfileId = uri.match(
        new RegExp('/Services/(.*)/PhoneNumbers')
      )![1];
      const body = mockTwilioUpdateNumberResponse({
        serviceProfileId,
        phoneNumber:
          options?.phoneNumber ?? faker.phone.phoneNumber('+1##########'),
        phoneSid: bodyFields.PhoneNumberSid,
      });
      return [200, body];
    });
};
