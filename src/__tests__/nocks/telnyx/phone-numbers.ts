import nock from 'nock';

import { TelnyxPhoneNumberStatus } from '../../../lib/types';
import { TELNYX_V2_API_URL } from './constants';

type PhoneNumber =
  | string
  | {
      phoneNumber: string;
      status?: TelnyxPhoneNumberStatus;
      serviceProfileId?: string;
    };

const mockTelnyxListResponse = (phoneNumbers: PhoneNumber[]) => ({
  data: phoneNumbers.map((record) => {
    const status: TelnyxPhoneNumberStatus =
      typeof record === 'string' ? 'active' : record.status ?? 'active';
    const phoneNumber: string =
      typeof record === 'string' ? record : record.phoneNumber;
    const serviceProfileId =
      typeof record === 'string' ? null : record.serviceProfileId ?? null;
    return {
      status,
      address_id: '',
      billing_group_id: null,
      call_forwarding_enabled: false,
      call_recording_enabled: false,
      cnam_listing_enabled: false,
      connection_id: '',
      created_at: '2019-11-13T22:33:26Z',
      emergency_enabled: false,
      external_pid: null,
      id: '12393xxxae717208350',
      messaging_profile_id: serviceProfileId,
      phone_number: phoneNumber,
      purchased_at: '2019-11-13T22:33:26Z',
      record_type: 'phone_number',
      t38_fax_gateway_enabled: true,
      tags: [],
      updated_at: '2019-11-13T22:33:26Z',
    };
  }),
  meta: {
    page_number: 1,
    page_size: 250,
    total_pages: 1,
    total_results: 1,
  },
});

const mockTelnyxDeleteResponse = (phoneNumber: string) => ({
  data: {
    address_id: '',
    billing_group_id: null,
    call_forwarding_enabled: false,
    call_recording_enabled: false,
    cnam_listing_enabled: false,
    connection_id: '',
    created_at: '2019-11-13T22:33:26Z',
    emergency_enabled: false,
    external_pid: null,
    id: '12393xxxae717208350',
    phone_number: phoneNumber,
    purchased_at: '2019-11-13T22:33:26Z',
    record_type: 'phone_number',
    status: 'active',
    t38_fax_gateway_enabled: true,
    tags: [],
    updated_at: '2019-11-13T22:33:26Z',
  },
});

const mockTelnyxDelete404Response = {
  errors: [
    {
      code: '10005',
      detail: 'The requested resource or URL could not be found.',
      meta: {
        url: 'https://developers.telnyx.com/docs/overview/errors/10005',
      },
      source: {
        pointer: '/',
      },
      title: 'Resource not found',
    },
  ],
};

export const nockGetNumbers = (phoneNumbers: PhoneNumber[]) =>
  nock(TELNYX_V2_API_URL)
    .get('/phone_numbers')
    .query(true)
    .reply(200, mockTelnyxListResponse(phoneNumbers));

type DeleteNumberResponse = 200 | 404;

export const nockDeleteNumber = (responseCode: DeleteNumberResponse) =>
  nock(TELNYX_V2_API_URL)
    .delete(new RegExp('/phone_numbers/[A-Za-z0-9]+'))
    .reply(responseCode, (uri) => {
      const phoneNumber = uri.match(
        new RegExp('/phone_numbers/([A-Za-z0-9]+)')
      )![1];
      if (responseCode === 404) {
        return mockTelnyxDelete404Response;
      }
      return mockTelnyxDeleteResponse(phoneNumber);
    });
