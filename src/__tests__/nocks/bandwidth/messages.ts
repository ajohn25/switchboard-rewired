import faker from 'faker';
import nock from 'nock';

import { MESSAGING_API_URL } from './constants';

interface CreateMessage200Options {
  serviceId?: string;
  numSegments?: number;
}

interface MessageResponseOptions {
  from: string;
  to: string;
  text: string;
  applicationId: string;
  media: string[];
}

const mock200Response = (
  options: CreateMessage200Options & MessageResponseOptions
) => ({
  id: options.serviceId ?? faker.random.alphaNumeric(29),
  owner: options.from,
  applicationId: options.applicationId,
  time: new Date().toISOString(),
  segmentCount: options.numSegments ?? 1,
  direction: 'out',
  to: [options.to],
  from: options.from,
  text: options.text,
  priority: 'default',
});

type NockCreateMessageOptions =
  | ({ code: '200' } & CreateMessage200Options)
  | { code: '400' };

export const nockCreateMessage = (options: NockCreateMessageOptions) =>
  nock(MESSAGING_API_URL)
    .post(/\/api\/v2\/users\/[\d]*\/messages/)
    .reply((uri, requestBody) => {
      if (typeof requestBody === 'string') return;
      const {
        from,
        to: [to],
        text,
        applicationId,
        media,
      } = requestBody;
      if (options.code === '200') {
        const { code, ...rest } = options;
        const body = mock200Response({
          ...rest,
          from,
          to,
          text,
          applicationId,
          media,
        });
        return [200, body];
      }
      if (options.code === '400') {
        const body = {
          type: 'request-validation',
          description: 'Your request could not be accepted',
        };
        return [400, body];
      }
    });

export const mockInboundMessagePayload = {
  type: 'message-received',
  time: '2016-09-14T18:20:16Z',
  description: 'Incoming message received',
  to: '+12345678902',
  message: {
    id: '14762070468292kw2fuqty55yp2b2',
    time: '2016-09-14T18:20:16Z',
    to: ['+12345678902'],
    from: '+12345678901',
    text: 'Hey, check this out!',
    applicationId: '93de2206-9669-4e07-948d-329f4b722ee2',
    media: [
      'https://messaging.bandwidth.com/api/v2/users/{accountId}/media/14762070468292kw2fuqty55yp2b2/0/bw.png',
    ],
    owner: '+12345678902',
    direction: 'in',
    segmentCount: 1,
  },
};
