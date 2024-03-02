import faker from 'faker';
import nock from 'nock';

import { parseUrlEncodedBody } from '../utils';
import { TWILIO_API_URL } from './constants';

const mock21610Response = {
  code: 21610,
  message: 'Attempt to send to unsubscribed recipient',
  more_info: 'http://www.twilio.com/docs/errors/21610',
  status: 400,
};

interface Mock200ResponseOptions {
  accountSid?: string;
  body?: string;
  from: string;
  to: string;
  sid: string;
  numSegments?: number;
  costInCents?: number;
}

const mock200Response = (options: Mock200ResponseOptions) => {
  const accountSid = options.accountSid ?? `AC${faker.random.alphaNumeric(32)}`;
  return {
    account_sid: accountSid,
    api_version: '2010-04-01',
    body: options.body ?? faker.hacker.phrase(),
    date_created: 'Thu, 30 Jul 2015 20:12:31 +0000',
    date_sent: 'Thu, 30 Jul 2015 20:12:33 +0000',
    date_updated: 'Thu, 30 Jul 2015 20:12:33 +0000',
    direction: 'outbound-api',
    error_code: null,
    error_message: null,
    from: options.from,
    messaging_service_sid: null,
    num_media: '0',
    num_segments: `${options.numSegments ?? 1}`,
    price: (((options.costInCents ?? 1) / 100) * -1).toString(),
    price_unit: 'USD',
    sid: options.sid,
    status: 'sent',
    to: options.to,
    uri: `/2010-04-01/Accounts/${accountSid}/Messages/${options.sid}.json`,
  };
};

type NockCreateMessageOptions =
  | {
      code: '200';
      twilioSid: string;
      costInCents?: number;
      numSegments?: number;
    }
  | { code: '21610' };

export const nockCreateMessage = (options: NockCreateMessageOptions) =>
  nock(TWILIO_API_URL)
    .post(new RegExp('/Accounts/[A-Za-z0-9]+/Messages.json'))
    .reply((uri, requestBody) => {
      if (options.code === '21610') {
        return [400, mock21610Response];
      }
      if (options.code === '200') {
        const fields = parseUrlEncodedBody(requestBody);
        const { To, From, Body } = fields;
        const body = mock200Response({
          body: Body,
          costInCents: options.costInCents,
          from: From,
          numSegments: options.numSegments,
          sid: options.twilioSid,
          to: To,
        });
        return [200, body];
      }
    });
