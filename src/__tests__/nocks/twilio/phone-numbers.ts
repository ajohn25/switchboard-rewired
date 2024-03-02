import faker from 'faker';
import nock from 'nock';
import url from 'url';

import { TwilioNumberPurchaseRequestBody } from '../../../lib/types';
import { parseUrlEncodedBody } from '../utils';
import { TWILIO_API_URL } from './constants';
import { fakeSid } from './utils';

export interface MockSetMessagingProfileOptions {
  phoneNumber: string;
  sid?: string;
}

export const mockTwilioUpdateNumberResponse = (
  options: MockSetMessagingProfileOptions
) => ({
  end: 0,
  first_page_uri:
    '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/IncomingPhoneNumbers.json?FriendlyName=friendly_name&Beta=true&PhoneNumber=%2B19876543210&PageSize=50&Page=0',
  incoming_phone_numbers: [
    {
      account_sid: 'ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      address_requirements: 'none',
      address_sid: 'ADXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      api_version: '2010-04-01',
      beta: null,
      bundle_sid: 'BUXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      capabilities: {
        fax: false,
        mms: true,
        sms: false,
        voice: true,
      },
      date_created: 'Thu, 30 Jul 2015 23:19:04 +0000',
      date_updated: 'Thu, 30 Jul 2015 23:19:04 +0000',
      emergency_address_sid: 'ADXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      emergency_status: 'Active',
      friendly_name: '(808) 925-5327',
      identity_sid: 'RIXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
      origin: 'origin',
      phone_number: options.phoneNumber,
      sid: options.sid ?? fakeSid(),
      sms_application_sid: '',
      sms_fallback_method: 'POST',
      sms_fallback_url: '',
      sms_method: 'POST',
      sms_url: '',
      status: 'in-use',
      status_callback: '',
      status_callback_method: 'POST',
      subresource_uris: {
        assigned_add_ons:
          '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/IncomingPhoneNumbers/PNXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/AssignedAddOns.json',
      },
      trunk_sid: null,
      uri: '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/IncomingPhoneNumbers/PNXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.json',
      voice_application_sid: '',
      voice_caller_id_lookup: false,
      voice_fallback_method: 'POST',
      voice_fallback_url: null,
      voice_method: 'POST',
      voice_receive_mode: 'voice',
      voice_url: null,
    },
  ],
  next_page_uri: null,
  page: 0,
  page_size: 50,
  previous_page_uri: null,
  start: 0,
  uri: '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/IncomingPhoneNumbers.json?FriendlyName=friendly_name&Beta=true&PhoneNumber=%2B19876543210&PageSize=50&Page=0',
});

const mockTwilioPurchaseNumberResponse = (options: {
  areaCode: string;
  exchange: string;
  lineNumber: string;
}): TwilioNumberPurchaseRequestBody => {
  const { areaCode, exchange, lineNumber } = options;
  return {
    account_sid: 'ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
    address_requirements: 'none',
    address_sid: '',
    api_version: '2010-04-01',
    beta: false,
    capabilities: { mms: true, sms: false, voice: true },
    date_created: 'Thu, 30 Jul 2015 23:19:04 +0000',
    date_updated: 'Thu, 30 Jul 2015 23:19:04 +0000',
    emergency_address_sid: '',
    emergency_status: 'Inactive',
    friendly_name: `(${areaCode}) ${exchange}-${lineNumber}`,
    identity_sid: 'RIXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
    origin: 'origin',
    phone_number: `+1${areaCode}${exchange}${lineNumber}`,
    sid: 'PNXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX',
    sms_application_sid: null,
    sms_fallback_method: 'POST',
    sms_fallback_url: '',
    sms_method: 'POST',
    sms_url: '',
    status_callback: '',
    status_callback_method: 'POST',
    trunk_sid: null,
    uri: '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/IncomingPhoneNumbers/PNXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.json',
    voice_application_sid: null,
    voice_caller_id_lookup: false,
    voice_fallback_method: 'POST',
    voice_fallback_url: null,
    voice_method: 'POST',
    voice_url: null,
  };
};

export type NockGetPhoneNumberIdOptions = Omit<
  MockSetMessagingProfileOptions,
  'phoneNumber'
>;

export const nockGetPhoneNumberId = (options: NockGetPhoneNumberIdOptions) => {
  nock(TWILIO_API_URL)
    .get(new RegExp('/Accounts/AC[A-Za-z0-9]+/IncomingPhoneNumbers.json'))
    .query(true)
    .reply((uri, requestBody) => {
      const { PhoneNumber } = url.parse(uri, true).query;
      const phoneNumber = Array.isArray(PhoneNumber)
        ? PhoneNumber[0]!
        : PhoneNumber!;
      const body = mockTwilioUpdateNumberResponse({
        phoneNumber,
        sid: options.sid,
      });
      return [200, body];
    });
};

type PurchaseNumberOptions = { callback?: (phoneNumber: string) => void } & (
  | { code: 400 }
  | { code: 200 }
);

export const nockPurchaseNumber = (options: PurchaseNumberOptions) =>
  nock(TWILIO_API_URL)
    .post(new RegExp('/Accounts/[A-Za-z0-9]+/IncomingPhoneNumbers.json'))
    .reply((uri, requestBody) => {
      const { code, callback } = options;
      if (code === 400) {
        return [code, 'Not found'];
      }
      if (code === 200) {
        const areaCode = parseUrlEncodedBody(requestBody).AreaCode;
        const exchange = faker.phone.phoneNumber(`###`);
        const lineNumber = faker.phone.phoneNumber(`####`);

        if (callback) {
          callback(`+1${areaCode}${exchange}${lineNumber}`);
        }
        const body = mockTwilioPurchaseNumberResponse({
          areaCode,
          exchange,
          lineNumber,
        });
        return [code, body];
      }
    });

export const nockDeleteNumber = () =>
  nock(TWILIO_API_URL)
    .delete(
      new RegExp(
        '/Accounts/AC[A-Za-z0-9]+/IncomingPhoneNumbers/PN[A-Za-z0-9]+.json'
      )
    )
    .reply(200, undefined);
