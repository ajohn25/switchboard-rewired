import faker from 'faker';
import nock from 'nock';
import url from 'url';
import xml2js from 'xml2js';

import { BANDWIDTH_API_URL } from './constants';

const mockBandwidthAvailableNumbers = (phoneNumbers: string[]) => {
  const result = new xml2js.Builder().buildObject({
    SearchResult: {
      ResultCount: phoneNumbers.length,
      TelephoneNumberList: phoneNumbers.map((phoneNumber) => ({
        TelephoneNumber: phoneNumber,
      })),
    },
  });
  return result;
};

type FinalOptions = {
  callback?: (phoneNumbers: string[]) => void;
} & (
  | { using: 'times'; times: number; targetCapacity: number }
  | { using: 'phoneNumbers'; phoneNumbers: string[] }
);

export const nockGetAvailableNumbers = (options: FinalOptions) =>
  nock(BANDWIDTH_API_URL)
    .get(/\/api\/accounts\/[\d]*\/availableNumbers/)
    .query((_) => true)
    .times(options.using === 'times' ? options.times : 1)
    .reply(200, (uri, requestBody) => {
      const { areaCode } = url.parse(uri, true).query;

      const phoneNumbers: string[] =
        options.using === 'phoneNumbers'
          ? options.phoneNumbers
          : [...Array(options.targetCapacity)].map((_) => {
              const exchange = faker.phone.phoneNumber('###');
              const lineNumber = faker.phone.phoneNumber('####');
              return `${areaCode}${exchange}${lineNumber}`;
            });

      const mockResponse = mockBandwidthAvailableNumbers(phoneNumbers);

      if (options.callback) {
        options.callback(phoneNumbers);
      }

      return mockResponse;
    });
