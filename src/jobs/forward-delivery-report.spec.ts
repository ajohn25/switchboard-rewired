import crypto from 'crypto';
import faker from 'faker';
import RedisMock from 'ioredis-mock';
import sample from 'lodash/sample';
import { Pool, PoolClient } from 'pg';
import supertest from 'supertest';

import {
  createClient,
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import { getMock } from '../__tests__/mocks';
import { SpokeNock } from '../__tests__/nocks';
import {
  fakeNumber,
  findGraphileWorkerJob,
  findJob,
  setClientIdConfig,
} from '../__tests__/numbers/utils';
import app from '../app';
import config from '../config';
import { crypt } from '../lib/crypt';
import { withClient } from '../lib/db';
import { ProcessMessagePayload } from '../lib/process-message';
import { defineCustomRedisCommands } from '../lib/redis';
import { RedisClient } from '../lib/redis/redis-index';
import { DeliveryReportEvent, Service } from '../lib/types';
import {
  FORWARD_DELIVERY_REPORT_IDENTIFIER,
  forwardDeliveryReport,
  ForwardDeliveryReportPayload,
} from './forward-delivery-report';
import {
  PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
  processGreyRouteMessage,
} from './process-grey-route-message';

let pool: Pool;

beforeAll(() => {
  pool = new Pool({ connectionString: config.databaseUrl });
});

afterAll(() => {
  return pool.end();
});

const sendAndProcessMessage = async (
  client: PoolClient,
  profileId: string,
  toNumber: string,
  body: string,
  mediaUrls: string[] | null,
  zip: string
) => {
  const {
    rows: [toProcess],
  } = await client.query(`select * from sms.send_message($1, $2, $3, $4, $5)`, [
    profileId,
    toNumber,
    faker.hacker.phrase(),
    mediaUrls,
    zip,
  ]);

  const foundJob = await findJob(
    client,
    PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
    'id',
    toProcess.id
  );

  const mockRedis = defineCustomRedisCommands(new RedisMock()) as RedisClient;

  const message = await processGreyRouteMessage(
    client,
    foundJob.payload as ProcessMessagePayload,
    mockRedis
  );

  return message;
};

const setupOutboundDeliveryReportToForward = async (
  client: PoolClient,
  myNumber: string,
  service: Service
) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service,
  });

  const { clientId } = await createClient(client, {});

  const sendingLocation = await createSendingLocation(client, {
    center: '11238',
    triggers: true,
    profile: {
      type: 'create',
      triggers: true,
      client: { type: 'existing', id: clientId },
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

  await setClientIdConfig(client, clientId);

  const {
    rows: [{ message_status_webhook_url, encrypted_client_access_token }],
  } = await client.query(
    `
      select message_status_webhook_url, access_token as encrypted_client_access_token
      from sms.profiles
      join billing.clients as clients on clients.id = sms.profiles.client_id
      where sms.profiles.sending_account_id = $1
    `,
    [sendingAccount.id]
  );

  const serviceId = faker.random.uuid();
  const eventType =
    sample([
      DeliveryReportEvent.Delivered,
      DeliveryReportEvent.DeliveryFailed,
    ]) ?? DeliveryReportEvent.Delivered;

  const insertOutboundMessage = async (): Promise<[string, string]> => {
    const message = await sendAndProcessMessage(
      client,
      sendingLocation.profile_id,
      fakeNumber(),
      faker.hacker.phrase(),
      null,
      '11238'
    );

    return [message.id, message.original_created_at.toISOString()];
  };

  const attachServiceIdToMessage = async (
    id: string,
    originalCreatedAt: string
  ) => {
    await client.query(
      `
        insert into sms.outbound_messages_telco (id, original_created_at, telco_status, service_id, num_segments, num_media, cost_in_cents, extra, profile_id)
        values ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      `,
      [
        id,
        originalCreatedAt,
        'sent',
        serviceId,
        1,
        0,
        0.0075,
        {},
        sendingLocation.profile_id,
      ]
    );
  };

  const [messageId, messageOriginalCreatedAt] = await insertOutboundMessage();
  await attachServiceIdToMessage(messageId, messageOriginalCreatedAt);

  const generatedAt = new Date().toISOString();
  const callbackBody = getMock(service).mockMessageDelivered(
    messageId,
    serviceId,
    eventType,
    generatedAt,
    messageOriginalCreatedAt
  );
  await supertest(app)
    .post(`/hooks/status/${sendingAccount.id}`)
    .send(callbackBody);

  const { rowCount: unresolvedMessageCount } = await client.query(
    `select * from sms.unmatched_delivery_reports where message_service_id = $1`,
    [serviceId]
  );

  await client.query('select sms.resolve_delivery_reports($1, $2)', [
    '1 minute',
    '0 seconds',
  ]);

  return {
    encrypted_client_access_token,
    eventType,
    messageId,
    message_status_webhook_url,
    unresolvedMessageCount,
  };
};

describe.each([
  [Service.Bandwidth, 0],
  [Service.Telnyx, 1],
  [Service.Twilio, 1],
])('forward %s delivery report', (service, expectedUnresolvedMessageCount) => {
  test('should include a correct signature heading', async () => {
    const [sentHeaders, sentExpectedSignature] = await withClient(
      pool,
      async (client) => {
        const myNumber = fakeNumber();

        const {
          eventType,
          messageId,
          message_status_webhook_url,
          encrypted_client_access_token,
        } = await setupOutboundDeliveryReportToForward(
          client,
          myNumber,
          service
        );

        const expectedSignature = crypto
          .createHmac('sha1', crypt.decrypt(encrypted_client_access_token))
          .update(`${messageId}|${eventType}`)
          .digest('hex');

        const queuedJob = await findGraphileWorkerJob(
          client,
          FORWARD_DELIVERY_REPORT_IDENTIFIER,
          'message_id',
          messageId
        );

        let headers: any = null;

        SpokeNock.genericRequest({
          callback: (reqHeaders) => (headers = reqHeaders),
          code: '200',
          url: message_status_webhook_url,
        });

        await forwardDeliveryReport(
          client,
          queuedJob.payload as ForwardDeliveryReportPayload
        );

        return [headers, expectedSignature];
      }
    );

    expect(sentHeaders).not.toBeNull();
    expect(sentHeaders).toHaveProperty('x-assemble-signature');
    expect(sentHeaders['x-assemble-signature']).toEqual(sentExpectedSignature);
  });

  test('should throw an error if bad status code and have required properties', async () => {
    const { log: forwardDeliveryReportLog, error: thrownError } =
      await withClient(pool, async (client) => {
        const myNumber = fakeNumber();

        const {
          eventType,
          messageId,
          unresolvedMessageCount,
          message_status_webhook_url,
        } = await setupOutboundDeliveryReportToForward(
          client,
          myNumber,
          service
        );

        expect(unresolvedMessageCount).toBe(expectedUnresolvedMessageCount);

        const queuedJob = await findGraphileWorkerJob(
          client,
          FORWARD_DELIVERY_REPORT_IDENTIFIER,
          'message_id',
          messageId
        );

        SpokeNock.genericRequest({
          code: '500',
          url: message_status_webhook_url,
        });

        let error = null;

        try {
          await forwardDeliveryReport(
            client,
            queuedJob.payload as ForwardDeliveryReportPayload
          );
        } catch (err: any) {
          error = err;
        }

        const {
          rows: [log],
        } = await client.query(
          'select * from sms.delivery_report_forward_attempts where message_id = $1 and event_type = $2',
          [messageId, eventType]
        );

        return { log, error };
      });

    expect(thrownError).not.toBeNull();
    expect(thrownError.status).toBe(500);
    expect(forwardDeliveryReportLog).toBeUndefined();
  });

  test('should queue the forward if the message comes in second', async () => {
    const { queuedJob: foundJob, messageId: delayedMessageId } =
      await withClient(pool, async (client) => {
        const myNumber = fakeNumber();

        const { eventType, messageId, message_status_webhook_url } =
          await setupOutboundDeliveryReportToForward(client, myNumber, service);

        const queuedJob = await findGraphileWorkerJob(
          client,
          FORWARD_DELIVERY_REPORT_IDENTIFIER,
          'message_id',
          messageId
        );

        return { queuedJob, messageId };
      });

    expect(foundJob).not.toBeNull();

    const payload = foundJob.payload as any;
    expect(payload.message_id).toEqual(delayedMessageId);
  });

  test('should have segment and media info', async () => {
    const foundJob = await withClient(pool, async (client) => {
      const myNumber = fakeNumber();

      const { messageId } = await setupOutboundDeliveryReportToForward(
        client,
        myNumber,
        Service.Bandwidth
      );

      const queuedJob = await findGraphileWorkerJob(
        client,
        FORWARD_DELIVERY_REPORT_IDENTIFIER,
        'message_id',
        messageId
      );

      return queuedJob;
    });

    expect(foundJob).not.toBeUndefined();
    const payload = foundJob.payload as any;
    expect(typeof payload.extra.num_segments).toBe('number');
  });
});
