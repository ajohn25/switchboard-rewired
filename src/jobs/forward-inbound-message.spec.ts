import crypto from 'crypto';
import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import {
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { SpokeNock } from '../__tests__/nocks';
import { fakeNumber, findJob } from '../__tests__/numbers/utils';
import config from '../config';
import { crypt } from '../lib/crypt';
import { Service } from '../lib/types';
import {
  FORWARD_INBOUND_MESSAGE_IDENTIFIER,
  forwardInboundMessage,
  ForwardInboundMessagePayload,
} from './forward-inbound-message';

const setupInboundMessageToForward = async (
  client: PoolClient,
  myNumber: string
) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service: Service.Telnyx,
  });

  const sendingLocation = await createSendingLocation(client, {
    center: '11238',
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
    phone_number: myNumber,
  });

  const {
    rows: [{ reply_webhook_url, encrypted_client_access_token }],
  } = await client.query(
    `select reply_webhook_url, access_token as encrypted_client_access_token from sms.profiles
    join billing.clients as clients on clients.id = sms.profiles.client_id
    where sms.profiles.sending_account_id = $1`,
    [sendingAccount.id]
  );

  // insert inbound message
  const {
    rows: [{ id: messageId }],
  } = await client.query(
    `insert into sms.inbound_messages (
      from_number, to_number, body, received_at, service, service_id,
      num_segments, num_media, media_urls, validated
    )
    values (
      $1, $2, $3, $4, $5, $6,
      $7, $8, $9, false
    )
    returning id`,
    [
      fakeNumber(),
      myNumber, // using myNumber ensures it'll get routed to the correct client / profile
      faker.hacker.phrase(),
      new Date().toISOString(),
      'telnyx',
      faker.internet.password(),
      1,
      0,
      [],
    ]
  );

  return { messageId, encrypted_client_access_token, reply_webhook_url };
};

describe('forward reply', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('should include a correct signature heading', async () => {
    const [sentHeaders, sentExpectedSignature] = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const myNumber = fakeNumber();

        const { encrypted_client_access_token, messageId, reply_webhook_url } =
          await setupInboundMessageToForward(client, myNumber);

        const expectedSignature = crypto
          .createHmac('sha1', crypt.decrypt(encrypted_client_access_token))
          .update(messageId)
          .digest('hex');

        const queuedJob = await findJob(
          client,
          FORWARD_INBOUND_MESSAGE_IDENTIFIER,
          'id',
          messageId
        );

        let headers: any = null;

        SpokeNock.genericRequest({
          callback: (reqHeaders) => (headers = reqHeaders),
          code: '200',
          url: reply_webhook_url,
        });

        await forwardInboundMessage(
          client,
          queuedJob.payload as ForwardInboundMessagePayload
        );
        return [headers, expectedSignature];
      }
    );

    expect(sentHeaders).not.toBeNull();
    expect(sentHeaders).toHaveProperty('x-assemble-signature');
    expect(sentHeaders['x-assemble-signature']).toEqual(sentExpectedSignature);
  });

  test('should throw an error if the client has a bad status code and have required properties', async () => {
    const { log: forwardAttemptLog, error: thrownError } =
      await withPgMiddlewares(
        pool,
        [autoRollbackMiddleware],
        async (client) => {
          const myNumber = fakeNumber();

          const { messageId, reply_webhook_url } =
            await setupInboundMessageToForward(client, myNumber);

          const queuedJob = await findJob(
            client,
            FORWARD_INBOUND_MESSAGE_IDENTIFIER,
            'id',
            messageId
          );

          SpokeNock.genericRequest({
            code: '500',
            url: reply_webhook_url,
          });

          let error = null;

          try {
            await forwardInboundMessage(
              client,
              queuedJob.payload as ForwardInboundMessagePayload
            );
          } catch (err) {
            error = err;
          }

          const {
            rows: [log],
          } = await client.query(
            'select * from sms.inbound_message_forward_attempts where message_id = $1',
            [messageId]
          );

          return { log, error };
        }
      );

    expect(thrownError).not.toBeNull();
    expect(forwardAttemptLog.response_status_code).toEqual(500);
    expect(forwardAttemptLog.sent_body).toHaveProperty('profileId');
    expect(forwardAttemptLog.sent_body.profileId).not.toBeNull();
    expect(forwardAttemptLog.sent_body).toHaveProperty('sendingLocationId');
    expect(forwardAttemptLog.sent_body.sendingLocationId).not.toBeNull();
  });
});
