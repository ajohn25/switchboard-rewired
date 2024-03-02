import faker from 'faker';
import RedisMock from 'ioredis-mock';
import { Pool, PoolClient } from 'pg';
import supertest from 'supertest';

import app from '../../app';
import config from '../../config';
import {
  PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
  processGreyRouteMessage,
} from '../../jobs/process-grey-route-message';
import { withClient } from '../../lib/db';
import { ProcessMessagePayload } from '../../lib/process-message';
import { defineCustomRedisCommands } from '../../lib/redis';
import { RedisClient } from '../../lib/redis/redis-index';
import {
  BandwidthDeliveryReportRequestBody,
  BandwidthDeliveryReportType,
  DeliveryReportEvent,
  Service,
  TelnyxDeliveryReportRequestBody,
  TwilioDeliveryReportRequestBody,
  TwilioDeliveryReportStatus,
} from '../../lib/types';
import {
  createClient,
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../fixtures';
import {
  destroySendingAccount,
  fakeNumber,
  findJob,
  setClientIdConfig,
} from './utils';

const setUpSendingLocation = async (
  client: PoolClient,
  service: Service,
  fromNumber: string
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
    phone_number: fromNumber,
  });

  await setClientIdConfig(client, clientId);

  return {
    sendingAccountId: sendingAccount.id,
    profileId: sendingLocation.profile_id,
    sendingLocationId: sendingLocation.id,
  };
};

const sendAndProcessMessage = async (
  client: PoolClient,
  profileId: string,
  toNumber: string
) => {
  const {
    rows: [toProcess],
  } = await client.query(`select * from sms.send_message($1, $2, $3, $4, $5)`, [
    profileId,
    toNumber,
    faker.hacker.phrase(),
    null,
    '11238',
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

describe('handling delivery reports', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('telnyx sending account properly decodes and writes delivery report', async () =>
    withClient(pool, async (client) => {
      const fromNumber = fakeNumber();
      const toNumber = fakeNumber();

      const { sendingAccountId, profileId } = await setUpSendingLocation(
        client,
        Service.Telnyx,
        fromNumber
      );

      const message = await sendAndProcessMessage(client, profileId, toNumber);

      // add a service id to it
      const serviceId = faker.random.uuid();
      const errorCode = faker.random
        .number({ min: 3000, max: 3010, precision: 1 })
        .toString();

      await client.query(
        `
        insert into sms.outbound_messages_telco (id, original_created_at, telco_status, service_id, num_segments, num_media, profile_id)
        values ($1, $2, $3, $4, $5, $6, $7)
      `,
        [
          message.id,
          message.original_created_at,
          'sent',
          serviceId,
          1,
          0,
          profileId,
        ]
      );

      const mockBody: TelnyxDeliveryReportRequestBody = {
        data: {
          payload: {
            carrier: faker.hacker.noun(),
            completed_at: new Date().toISOString(),
            cost: {
              amount: '0.0045',
              currency: null,
            },
            errors: [
              {
                code: errorCode,
                detail: faker.random.word(),
                title: faker.random.word(),
              },
            ],
            id: serviceId,
            line_type: faker.hacker.verb(),
            to: [
              {
                address: toNumber,
                status: DeliveryReportEvent.DeliveryFailed,
              },
            ],
          },
        },
      };

      // mock delivery report request - no reason to mock validation headers,
      // going to fail anyways
      const response = await supertest(app)
        .post(`/hooks/status/${sendingAccountId}`)
        .send(mockBody);

      expect(response.status).toBe(200);

      // check that unmatched delivery reports has the mocked service id
      const {
        rows: [foundReport],
      } = await client.query(
        'select * from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      const {
        rows: [resultingMessage],
      } = await client.query(
        'select * from sms.outbound_messages_telco where id = $1',
        [message.id]
      );

      await destroySendingAccount(sendingAccountId);

      await client.query(
        'delete from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      expect(foundReport.message_service_id).toEqual(serviceId);
      expect(foundReport.event_type).toEqual(
        DeliveryReportEvent.DeliveryFailed
      );

      // check that the cost has been applied to the outbound message
      if (config.trackCost) {
        expect(parseFloat(resultingMessage.cost_in_cents)).toEqual(0.45);
      }
    }));

  test('twilio sending account properly decodes and writes message', async () =>
    withClient(pool, async (client) => {
      const fromNumber = fakeNumber();
      const toNumber = fakeNumber();

      const { sendingAccountId, profileId } = await setUpSendingLocation(
        client,
        Service.Twilio,
        fromNumber
      );

      const message = await sendAndProcessMessage(client, profileId, toNumber);

      // add a service id to it - use alphanumeric to match twilio
      const serviceId = faker.random.alphaNumeric(10);
      const errorCode = faker.random
        .number({ min: 3000, max: 3010, precision: 1 })
        .toString();

      const mockBody: TwilioDeliveryReportRequestBody = {
        ErrorCode: errorCode,
        MessageStatus: TwilioDeliveryReportStatus.Undelivered,
        SmsSid: serviceId,
        SmsStatus: TwilioDeliveryReportStatus.Undelivered,
      };

      // mock delivery report request - no reason to mock validation headers,
      // going to fail anyways
      const response = await supertest(app)
        .post(`/hooks/status/${sendingAccountId}`)
        .send(mockBody);

      expect(response.status).toBe(200);

      // check that it has the mocked service id
      const {
        rows: [foundReport],
      } = await client.query(
        'select * from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      await destroySendingAccount(sendingAccountId);

      await client.query(
        'delete from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      expect(foundReport.message_service_id).toEqual(serviceId);
      expect(foundReport.event_type).toEqual(
        DeliveryReportEvent.DeliveryFailed
      );
    }));

  test('bandwidth sending account properly decodes and writes message', async () =>
    withClient(pool, async (client) => {
      const fromNumber = fakeNumber();
      const toNumber = fakeNumber();

      const { sendingAccountId, profileId } = await setUpSendingLocation(
        client,
        Service.Bandwidth,
        fromNumber
      );

      const message = await sendAndProcessMessage(client, profileId, toNumber);

      // add a service id to it - use alphanumeric to match twilio
      const serviceId = faker.random.alphaNumeric(29);
      const errorCode = faker.random.number({
        min: 3000,
        max: 3010,
        precision: 1,
      });

      const time = new Date().toISOString();

      const mockBody: BandwidthDeliveryReportRequestBody = [
        {
          type: BandwidthDeliveryReportType.Failed,
          time,
          description: faker.hacker.phrase(),
          to: toNumber,
          errorCode,
          message: {
            id: serviceId,
            time,
            to: [toNumber],
            from: fromNumber,
            text: faker.hacker.phrase(),
            applicationId: faker.random.uuid(),
            media: [],
            owner: fromNumber,
            direction: 'out',
            segmentCount: 2,
          },
        },
      ];

      // mock delivery report request - no reason to mock validation headers,
      // going to fail anyways
      const response = await supertest(app)
        .post(`/hooks/status/${sendingAccountId}`)
        .send(mockBody);

      expect(response.status).toBe(200);

      // check that it has the mocked service id
      const {
        rows: [foundReport],
      } = await client.query(
        'select * from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      await destroySendingAccount(sendingAccountId);

      await client.query(
        'delete from sms.unmatched_delivery_reports where message_service_id = $1',
        [serviceId]
      );

      expect(foundReport.message_service_id).toEqual(serviceId);
      expect(foundReport.event_type).toEqual(
        DeliveryReportEvent.DeliveryFailed
      );
    }));
});
