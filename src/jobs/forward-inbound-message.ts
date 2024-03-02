import crypto from 'crypto';
import { PoolClient } from 'pg';
import superagent, { Response } from 'superagent';
import { z } from 'zod';

import { crypt } from '../lib/crypt';
import { requestWith302Override } from '../lib/utils';
import { errToObj, logger } from '../logger';
import { ProfileSendingAccountPayloadSchema } from './schema-validation';

export const FORWARD_INBOUND_MESSAGE_IDENTIFIER = 'forward-inbound-message';

// tslint:disable-next-line variable-name
export const ForwardInboundMessagePayloadSchema =
  ProfileSendingAccountPayloadSchema.omit({
    voice_callback_url: true,
    tendlc_campaign_id: true,
    sending_account_id: true,
  })
    .extend({
      id: z.string().uuid(),
      sending_location_id: z.string().uuid(),
      from_number: z.string(),
      to_number: z.string(),
      body: z.string(),
      received_at: z.string(),
      num_segments: z.number().int(),
      num_media: z.number().int(),
      media_urls: z.array(z.string()),
    })
    .required();

export type ForwardInboundMessagePayload = z.infer<
  typeof ForwardInboundMessagePayloadSchema
>;

const constructSignature = (payload: ForwardInboundMessagePayload) => {
  const clientAccessToken = crypt.decrypt(
    payload.encrypted_client_access_token
  );

  return crypto
    .createHmac('sha1', clientAccessToken)
    .update(payload.id)
    .digest('hex');
};

/**
 * The message fields the client receives should match the ones
 * they were sent – this interface matches postgraphile's
 * camel case inflection
 */
interface ForwardedMessage {
  id: string;
  from: string;
  to: string;
  body: string;
  receivedAt: string;
  numSegments: number;
  numMedia: number;
  mediaUrls: string[];
  profileId: string;
  sendingLocationId: string;
}

/**
 *  Constructs a signature based on the access token and message id,
 *  sends the request to the right url, logs the attempt and response
 *  fails if it got an error, triggering worker retry behavior
 * @param client PoolClient
 * @param payload phone number request
 */
export const forwardInboundMessage = async (
  client: PoolClient,
  rawPayload: unknown
) => {
  const payload = ForwardInboundMessagePayloadSchema.parse(rawPayload);

  const signature = constructSignature(payload);

  const toForward: ForwardedMessage = {
    body: payload.body,
    from: payload.from_number,
    id: payload.id,
    mediaUrls: payload.media_urls,
    numMedia: payload.num_media,
    numSegments: payload.num_segments,
    profileId: payload.profile_id,
    receivedAt: payload.received_at,
    sendingLocationId: payload.sending_location_id,
    to: payload.to_number,
  };

  const sentAt = new Date();

  const headers = {
    'x-assemble-signature': signature,
  };

  let response: Response;

  try {
    response = await requestWith302Override(
      payload.reply_webhook_url,
      (url: string) => superagent.post(url).set(headers).send(toForward)
    );
  } catch (err: any) {
    if (err.response) {
      response = err.response;
    } else {
      logger.error('Unexpected error forwarding inbound message', {
        error: errToObj(err),
      });
      throw err;
    }
  }

  const status = response.status;

  await client.query(
    `
    insert into sms.inbound_message_forward_attempts
    (message_id, sent_at, sent_headers, sent_body, response_status_code, response_headers, response_body) values
    ($1, $2, $3, $4, $5, $6, $7)
  `,
    [
      payload.id,
      sentAt.toISOString(),
      headers,
      toForward,
      status,
      response.header,
      response.text,
    ]
  );

  /**
   * response.ok is false if 400 or 500 status (or no response or something else)
   */
  if (!response.ok) {
    throw new Error(
      `Client did not handle inbound message forward attempt correctly – got status ${status} and body ${response.text}`
    );
  }
};
