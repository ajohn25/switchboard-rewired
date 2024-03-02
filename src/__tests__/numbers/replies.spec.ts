import faker from 'faker';
import { Pool } from 'pg';
import supertest from 'supertest';

import app from '../../app';
import config from '../../config';
import { sql } from '../../db';
import { FORWARD_INBOUND_MESSAGE_IDENTIFIER } from '../../jobs/forward-inbound-message';
import { crypt } from '../../lib/crypt';
import { withClient } from '../../lib/db';
import { Service, TwilioReplyRequestBody } from '../../lib/types';
import {
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../fixtures';
import { withReplicaMode } from '../helpers';
import { mockInboundMessagePayload } from '../nocks/bandwidth/messages';
import {
  destroySendingAccount,
  fetchAndDestroyMessage,
  findJob,
  mockTelnyxMessage,
  mockTwilioMessage,
} from './utils';

const setUpSending = async (
  pool: Pool,
  service: Service,
  fromNumber: string
) => {
  const result = await withClient(pool, async (client) => {
    const sendingAccount = await createSendingAccount(client, {
      service,
      triggers: true,
    });

    const sendingLocation = await createSendingLocation(client, {
      center: '10001',
      triggers: true,
      profile: {
        type: 'create',
        triggers: true,
        client: { type: 'create' },
        sending_account: { type: 'existing', id: sendingAccount.id },
        profile_service_configuration: {
          type: 'create',
          profile_service_configuration_id: faker.random.uuid(),
        },
      },
    });

    await createPhoneNumber(client, {
      sending_location_id: sendingLocation.id,
      phone_number: fromNumber,
    });

    return {
      sendingAccount,
      sendingAccountId: sendingAccount.id,
      sendingLocationId: sendingLocation.id,
    };
  });
  return result;
};

describe('handling replies', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('telnyx sending account properly decodes and writes message', async () => {
    const { sendingAccountId } = await setUpSending(
      pool,
      Service.Telnyx,
      mockTelnyxMessage.body.data.payload.to
    );

    const response = await supertest(app)
      .post(`/hooks/reply/${sendingAccountId}`)
      .set(mockTelnyxMessage.headers)
      .send(mockTelnyxMessage.body);

    expect(response.status).toBe(200);

    const messageId = response.header['x-created-message-id'];
    const insertedMessage = await fetchAndDestroyMessage(messageId);
    await destroySendingAccount(sendingAccountId);

    expect(insertedMessage.from).toEqual(
      mockTelnyxMessage.body.data.payload.from.phone_number
    );
    expect(insertedMessage.to).toEqual(mockTelnyxMessage.body.data.payload.to);
    expect(insertedMessage.body).toEqual(
      mockTelnyxMessage.body.data.payload.text
    );
    expect(insertedMessage.mediaUrls).toEqual(
      `{${mockTelnyxMessage.body.data.payload.media[0].url}}` // this is what a postgresql string array looks like
    );

    const forwardReplyJob = await findJob(
      pool,
      FORWARD_INBOUND_MESSAGE_IDENTIFIER,
      'id',
      messageId
    );

    expect(forwardReplyJob.payload).toHaveProperty('reply_webhook_url');
  });

  test('twilio sending account properly decodes and writes message', async () => {
    const { sendingAccountId } = await setUpSending(
      pool,
      Service.Twilio,
      mockTwilioMessage.body.To
    );

    const response = await supertest(app)
      .post(`/hooks/reply/${sendingAccountId}`)
      .type('form')
      .set(mockTwilioMessage.headers)
      .send(mockTwilioMessage.body);

    expect(response.status).toBe(200);

    const messageId = response.header['x-created-message-id'];
    const insertedMessage = await fetchAndDestroyMessage(messageId);
    await destroySendingAccount(sendingAccountId);

    expect(insertedMessage.from).toEqual(mockTwilioMessage.body.From);
    expect(insertedMessage.to).toEqual(mockTwilioMessage.body.To);
    expect(insertedMessage.body).toEqual(mockTwilioMessage.body.Body);

    const forwardReplyJob = await findJob(
      pool,
      FORWARD_INBOUND_MESSAGE_IDENTIFIER,
      'id',
      messageId
    );

    expect(forwardReplyJob.payload).toHaveProperty('reply_webhook_url');
  });

  test('bandwidth sending account properly decodes and writes message', async () => {
    const {
      sendingAccount: { bandwidth_credentials },
      sendingAccountId,
    } = await setUpSending(
      pool,
      Service.Bandwidth,
      mockInboundMessagePayload.to
    );

    const { callback_username: username, callback_encrypted_password } =
      bandwidth_credentials!;
    const password = crypt.decrypt(callback_encrypted_password);

    const response = await supertest(app)
      .post(`/hooks/reply/${sendingAccountId}`)
      .type('form')
      .auth(username, password)
      .set('Content-Type', 'application/json; charset=utf-8')
      .send([mockInboundMessagePayload]);

    expect(response.status).toBe(200);

    const messageId = response.header['x-created-message-id'];
    const insertedMessage = await fetchAndDestroyMessage(messageId);
    await destroySendingAccount(sendingAccountId);

    expect(insertedMessage.from).toEqual(
      mockInboundMessagePayload.message.from
    );
    expect(insertedMessage.to).toEqual(mockInboundMessagePayload.message.to[0]);
    expect(insertedMessage.body).toEqual(
      mockInboundMessagePayload.message.text
    );

    const forwardReplyJob = await findJob(
      pool,
      FORWARD_INBOUND_MESSAGE_IDENTIFIER,
      'id',
      messageId
    );

    expect(forwardReplyJob.payload).toHaveProperty('reply_webhook_url');
  });

  test('messages from short code numbers are ignored', async () => {
    const { sendingAccountId, sendingLocationId } = await setUpSending(
      pool,
      Service.Twilio,
      mockTwilioMessage.body.To
    );

    const shortCodeBody: TwilioReplyRequestBody = {
      ...mockTwilioMessage.body,
      From: '+623623',
    };

    const response = await supertest(app)
      .post(`/hooks/reply/${sendingAccountId}`)
      .type('form')
      .set(mockTwilioMessage.headers)
      .send(shortCodeBody);

    expect(response.status).toBe(200);
    expect(response.header['x-created-message-id']).toBeUndefined();

    const query = sql`select count(*) from sms.inbound_messages where sending_location_id = ${sendingLocationId}`;
    const {
      rows: [{ count: rowCount }],
    } = await pool.query(query.sql, [...query.values]);

    await destroySendingAccount(sendingAccountId);

    expect(parseInt(rowCount, 10)).toEqual(0);
  });

  test('inbound sent to released TN returns 200 response', async () => {
    const {
      sendingAccount: { bandwidth_credentials },
      sendingAccountId,
      sendingLocationId,
    } = await setUpSending(
      pool,
      Service.Bandwidth,
      mockInboundMessagePayload.to
    );

    await withClient(pool, async (poolClient) =>
      withReplicaMode(poolClient, async (client) => {
        await client.query(
          `update sms.all_phone_numbers set released_at = now() where sending_location_id = $1`,
          [sendingLocationId]
        );
      })
    );

    const { callback_username: username, callback_encrypted_password } =
      bandwidth_credentials!;
    const password = crypt.decrypt(callback_encrypted_password);

    const response = await supertest(app)
      .post(`/hooks/reply/${sendingAccountId}`)
      .type('form')
      .auth(username, password)
      .set('Content-Type', 'application/json; charset=utf-8')
      .send([mockInboundMessagePayload]);

    expect(response.status).toBe(200);

    const messageId = response.header['x-created-message-id'];
    expect(messageId).toBeUndefined();

    await destroySendingAccount(sendingAccountId);

    const forwardReplyJob = await findJob(
      pool,
      FORWARD_INBOUND_MESSAGE_IDENTIFIER,
      'sending_location_id',
      sendingLocationId
    );

    expect(forwardReplyJob).toBeUndefined();
  });
});
