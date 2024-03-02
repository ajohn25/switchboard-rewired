import faker from 'faker';
import nock from 'nock';
import url from 'url';

import { TwilioGetNumbersResponse } from '../../../lib/types';
import { TWILIO_API_URL } from './constants';

export const nockTwilioNumberAvailability = (
  times: number,
  targetCapacity: number,
  onlyMatch?: string
) => {
  nock(TWILIO_API_URL)
    .get(
      new RegExp('/Accounts/[A-Za-z0-9]+/AvailablePhoneNumbers/US/Local.json')
    )
    .query((_) => true)
    .times(times)
    .reply(200, (uri, _requestBody) => {
      const areaCode = url.parse(uri, true).query.AreaCode;
      const exchange = faker.phone.phoneNumber('###');
      const lineNumber = faker.phone.phoneNumber('####');

      const count =
        onlyMatch === undefined
          ? targetCapacity
          : areaCode === onlyMatch
          ? targetCapacity
          : 0;

      const availablePhoneNumbers = [...Array(count)].map((_) => ({
        address_requirements: 'none',
        beta: false,
        capabilities: {
          mms: true,
          sms: false,
          voice: true,
        },
        friendly_name: `(${areaCode}) ${exchange}-${lineNumber}`,
        iso_country: 'US',
        lata: '834',
        latitude: '19.720000',
        locality: faker.address.city(),
        longitude: '-155.090000',
        phone_number: `+1${areaCode}${exchange}${lineNumber}`,
        postal_code: faker.address.zipCode(),
        rate_center: faker.address.city().toUpperCase(),
        region: faker.address.stateAbbr(),
      }));

      const mockResponse: TwilioGetNumbersResponse = {
        available_phone_numbers: availablePhoneNumbers,
        end: 1,
        first_page_uri:
          '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/AvailablePhoneNumbers/US/Local.json?PageSize=50&Page=0',
        last_page_uri:
          '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/AvailablePhoneNumbers/US/Local.json?PageSize=50&Page=0',
        next_page_uri: null,
        num_pages: 1,
        page: 0,
        page_size: 50,
        previous_page_uri:
          '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/AvailablePhoneNumbers/US/Local.json?PageSize=50&Page=0',
        start: 0,
        total: targetCapacity,
        uri: '/2010-04-01/Accounts/ACXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX/AvailablePhoneNumbers/US/Local.json?PageSize=1',
      };

      return mockResponse;
    });
};
