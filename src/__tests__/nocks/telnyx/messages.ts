import faker from 'faker';
import nock from 'nock';

import { TELNYX_V2_API_URL } from './constants';

interface CreateMessage200Options {
  serviceId: string;
  numSegments?: number;
}

const mock200Response = (options: CreateMessage200Options) => ({
  data: {
    carrier: faker.random.word(),
    id: options.serviceId,
    line_type: faker.random.word(),
    media_urls: [],
    parts: options.numSegments ?? 1,
  },
});

interface CreateMessage409Options {
  fromNumber: string;
  toNumber: string;
}

const mock40300Response = ({
  fromNumber,
  toNumber,
}: CreateMessage409Options) => ({
  errors: [
    {
      code: '40300',
      detail: `Messages cannot be sent from '${fromNumber}' to '${toNumber}' due to an existing block rule.`,
      meta: {
        url: 'https://developers.telnyx.com/docs/overview/errors/40300',
      },
      title: 'Blocked due to STOP message',
    },
  ],
});

const mock40006Response = () => ({
  errors: [
    {
      code: '40006', // Recipient server unavailable
      detail:
        'The recipient server is unavailable or not responding. This may be a temporary issue. If the error persists, contact Telnyx support.',
      meta: {
        url: 'https://developers.telnyx.com/docs/overview/errors/40006',
      },
      title: 'Recipient server unavailable',
    },
  ],
});

const mock40305Response = () => ({
  errors: [
    {
      code: '40305', // Invalid 'from' address
      detail:
        "The 'from' address should be string containing a valid number associated with the sending messaging profile.",
      meta: {
        url: 'https://developers.telnyx.com/docs/overview/errors/40305',
      },
      title: "Invalid 'from' address",
    },
  ],
});

type NockCreateMessageOptions =
  | ({ code: '200' } & CreateMessage200Options)
  | { code: '40006' }
  | { code: '40305' }
  | { code: '40300' };

export const nockCreateMessage = (options: NockCreateMessageOptions) =>
  nock(TELNYX_V2_API_URL)
    .post('/messages')
    .reply((uri, requestBody) => {
      const { from, to } = requestBody as any;
      if (options.code === '200') {
        const { code, ...rest } = options;
        const body = mock200Response(rest);
        return [200, body];
      }
      if (options.code === '40006') {
        const body = mock40006Response();
        return [400, body];
      }
      if (options.code === '40305') {
        const body = mock40305Response();
        return [400, body];
      }
      if (options.code === '40300') {
        const body = mock40300Response({ fromNumber: from, toNumber: to });
        return [409, body];
      }
    });
