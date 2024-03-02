import faker from 'faker';
import nock from 'nock';
import url from 'url';

import { TelnyxSearchNumbersResponse } from '../../../lib/types';
import { TELNYX_V2_API_URL } from './constants';

interface GetNumbersTimesCapactiy {
  times: number;
  targetCapacity: number;
}

interface GetAvailableNumbersOptions {
  times: GetNumbersTimesCapactiy;
  phoneNumbers: string[];
}

type FinalOptions = {
  callback?: (phoneNumbers: string[]) => void;
} & (
  | { using: 'times'; times: number; targetCapacity: number }
  | { using: 'phoneNumbers'; phoneNumbers: string[] }
);

export const nockGetAvailableNumbers = (options: FinalOptions) =>
  nock(TELNYX_V2_API_URL)
    .get('/available_phone_numbers')
    .query((_) => true)
    .times(options.using === 'times' ? options.times : 1)
    .reply(200, (uri, requestBody) => {
      const areaCode = url.parse(uri, true).query[
        'filter[national_destination_code]'
      ];

      const phoneNumbers: string[] =
        options.using === 'phoneNumbers'
          ? options.phoneNumbers
          : [...Array(options.targetCapacity)].map((_) => {
              const exchange = faker.phone.phoneNumber('###');
              const lineNumber = faker.phone.phoneNumber('####');
              return `+1${areaCode}${exchange}${lineNumber}`;
            });

      const data = phoneNumbers.map((phoneNumber) => {
        return {
          best_effort: false,
          cost_information: {
            currency: 'USD',
            monthly_cost: '1.00000',
            upfront_cost: '1.00000',
          },
          features: [{ name: 'fax' }, { name: 'voice' }, { name: 'sms' }],
          phone_number: phoneNumber,
          record_type: 'available_phone_number',
          region_information: [],
          reservable: false,
          vanity_format: null,
        };
      });

      const mockResponse: TelnyxSearchNumbersResponse = {
        data,
        metadata: {
          best_effort_results: 0,
          total_results: phoneNumbers.length,
        },
      };

      if (options.callback) {
        options.callback(phoneNumbers);
      }

      return mockResponse;
    });
