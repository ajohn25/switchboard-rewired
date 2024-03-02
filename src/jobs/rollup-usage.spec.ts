import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import {
  createClient,
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { setClientIdConfig } from '../__tests__/numbers/utils';
import config from '../config';
import {
  LrnUsageRollupRow,
  MessagingUsageRollupRow,
  Service,
} from '../lib/types';

const makePeriodEnd = () => {
  const periodEnd = new Date();
  periodEnd.setMinutes(0);
  periodEnd.setSeconds(0);
  periodEnd.setMilliseconds(0);
  return periodEnd;
};

const generateRollups = (options: { client: PoolClient; periodEnd: Date }) => {
  const fireDate = new Date(options.periodEnd.getTime());
  fireDate.setMinutes(fireDate.getMinutes() + 2);
  options.client.query(`select billing.generate_usage_rollups($1)`, [fireDate]);
};

const insertLrnUsage = async (options: {
  client: PoolClient;
  clientId: string;
  periodEnd: Date;
  intervalMinutes: number;
  count: number;
  status?: string;
}) => {
  const {
    client,
    clientId,
    count,
    periodEnd,
    intervalMinutes,
    status = 'done',
  } = options;
  await Promise.all(
    [...Array(count)].map(async (_) => {
      const phoneNumber = faker.phone.phoneNumber('+1##########');
      const accessedAt = new Date(periodEnd.getTime());
      const offset = Math.floor(Math.random() * intervalMinutes) + 1;
      accessedAt.setMinutes(accessedAt.getMinutes() - offset);
      await client.query(
        `
          insert into lookup.accesses (
            client_id,
            phone_number,
            accessed_at,
            state
          )
          values ($1, $2, $3, $4)
        `,
        [clientId, phoneNumber, accessedAt, status]
      );
    })
  );
};

const insertInboundMessages = async (options: {
  client: PoolClient;
  sendingLocationId: string;
  toNumber: string;
  count: number;
  periodEnd: Date;
  intervalMinutes: number;
}) => {
  const {
    client,
    sendingLocationId,
    toNumber,
    count,
    periodEnd,
    intervalMinutes,
  } = options;

  let totalSegments = 0;

  await Promise.all(
    [...Array(count)].map(async (_) => {
      const fromNumber = faker.phone.phoneNumber('+1917#######');
      const body = faker.random.words(10);
      const receivedAt = new Date(periodEnd.getTime());
      const offset = Math.floor(Math.random() * intervalMinutes) + 1;
      receivedAt.setMinutes(receivedAt.getMinutes() - offset);
      const numSegments = Math.round(Math.random() * 4);
      totalSegments += numSegments;

      await client.query(
        `
          insert into sms.inbound_messages (
            sending_location_id,
            from_number,
            to_number,
            body,
            received_at,
            service,
            service_id,
            num_segments,
            num_media,
            media_urls,
            validated
          ) values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11);
        `,
        [
          sendingLocationId,
          fromNumber,
          toNumber,
          body,
          receivedAt,
          'telnyx',
          faker.internet.password(),
          numSegments,
          0,
          [],
          true,
        ]
      );
    })
  );

  return { totalSegments };
};

const insertOutboundMessages = async (options: {
  client: PoolClient;
  profileId: string;
  sendingLocationId: string;
  fromNumber: string;
  count: number;
  periodEnd: Date;
  intervalMinutes: number;
}) => {
  const {
    client,
    profileId,
    sendingLocationId,
    fromNumber,
    count,
    periodEnd,
    intervalMinutes,
  } = options;

  let totalSegments = 0;

  await Promise.all(
    [...Array(count)].map(async (_) => {
      const toNumber = faker.phone.phoneNumber('+1917#######');
      const body = faker.random.words(10);
      const createdAt = new Date(periodEnd.getTime());
      const offset = Math.floor(Math.random() * intervalMinutes) + 1;
      createdAt.setMinutes(createdAt.getMinutes() - offset);
      const numSegments = Math.round(Math.random() * 4);
      totalSegments += numSegments;

      const {
        rows: [{ id: messageId }],
      } = await client.query<{
        id: string;
      }>(
        `
        insert into sms.outbound_messages (
          profile_id,
          to_number,
          stage,
          body,
          media_urls,
          contact_zip_code,
          created_at
        )
        values ($1, $2, $3, $4, $5, $6, $7)
        returning id;
      `,
        [profileId, toNumber, 'processing', body, [], '11206', createdAt]
      );

      await client.query(
        `
          insert into sms.outbound_messages_routing (
            id,
            to_number,
            from_number,
            estimated_segments,
            stage,
            decision_stage,
            first_from_to_pair_of_day,
            sending_location_id,
            original_created_at,
            processed_at,
            profile_id
          )
          values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        `,
        [
          messageId,
          toNumber,
          fromNumber,
          1,
          'sent',
          'prev_mapping',
          true,
          sendingLocationId,
          createdAt,
          createdAt,
          profileId,
        ]
      );

      await client.query(
        `
          insert into sms.outbound_messages_telco (
            id,
            service_id,
            telco_status,
            num_segments,
            num_media,
            sent_at,
            original_created_at,
            profile_id
          )
          values ($1, $2, $3, $4, $5, $6, $7, $8)
        `,
        [
          messageId,
          faker.internet.password(),
          'delivered',
          numSegments,
          0,
          createdAt,
          createdAt,
          profileId,
        ]
      );
    })
  );

  return { totalSegments };
};

const setUpSendingLocation = async (client: PoolClient, fromNumber: string) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service: Service.Telnyx,
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

  return sendingLocation;
};

describe('rollup usage', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('should rollup client lrn usage for a period', async () => {
    const periodEnd = makePeriodEnd();
    const lrnCount = Math.round(Math.random() * 1000 + 200);

    const testRunResults = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const {
          rows: [{ id: clientId }],
        } = await client.query<{ id: string }>(
          `insert into billing.clients (name) values ($1) returning id`,
          [faker.company.companyName()]
        );

        // Insert usage within period
        await insertLrnUsage({
          client,
          clientId,
          periodEnd,
          count: lrnCount,
          intervalMinutes: 30,
        });

        // Insert usage outside of period
        const oldUsagePeriodEnd = new Date(periodEnd.getTime());
        oldUsagePeriodEnd.setHours(oldUsagePeriodEnd.getHours() - 3);
        await insertLrnUsage({
          client,
          clientId,
          count: Math.floor(Math.random() * 1000 + 200),
          intervalMinutes: 30,
          periodEnd: oldUsagePeriodEnd,
        });

        await generateRollups({ client, periodEnd });

        const {
          rows: [report],
        } = await client.query<LrnUsageRollupRow>(
          `select * from billing.lrn_usage_rollups where client_id = $1 and period_end = $2`,
          [clientId, periodEnd]
        );

        return { report };
      }
    );

    expect(testRunResults.report.lrn).toEqual(lrnCount);
  });

  test('should rollup client messaging usage for a period', async () => {
    const fromNumber = faker.phone.phoneNumber('+1917#######');
    const periodEnd = makePeriodEnd();
    const inboundMessageCount = Math.round(Math.random() * 5 + 3);
    const outboundMessageCount = Math.round(Math.random() * 5 + 3);

    const testRunResults = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const sendingLocation = await setUpSendingLocation(client, fromNumber);
        const { id: sendingLocationId, profile_id: profileId } =
          sendingLocation;

        const { totalSegments: inboundSegments } = await insertInboundMessages({
          client,
          periodEnd,
          sendingLocationId,
          count: inboundMessageCount,
          intervalMinutes: 30,
          toNumber: fromNumber,
        });

        const { totalSegments: outboundSegments } =
          await insertOutboundMessages({
            client,
            fromNumber,
            periodEnd,
            profileId,
            sendingLocationId,
            count: outboundMessageCount,
            intervalMinutes: 30,
          });

        await generateRollups({ client, periodEnd });

        const {
          rows: [report],
        } = await client.query<MessagingUsageRollupRow>(
          `select * from billing.messaging_usage_rollups where profile_id = $1 and period_end = $2`,
          [profileId, periodEnd]
        );

        return { inboundSegments, outboundSegments, report };
      }
    );

    expect(testRunResults.report.outbound_sms_messages).toEqual(
      outboundMessageCount
    );
    expect(testRunResults.report.outbound_sms_segments).toEqual(
      testRunResults.outboundSegments
    );
    expect(testRunResults.report.outbound_mms_messages).toEqual(0);
    expect(testRunResults.report.outbound_mms_segments).toEqual(0);
    expect(testRunResults.report.inbound_sms_messages).toEqual(
      inboundMessageCount
    );
    expect(testRunResults.report.inbound_sms_segments).toEqual(
      testRunResults.inboundSegments
    );
    expect(testRunResults.report.inbound_mms_messages).toEqual(0);
    expect(testRunResults.report.inbound_mms_segments).toEqual(0);
  });

  test('should ignore client messaging usage outside of rollup period', async () => {
    const fromNumber = faker.phone.phoneNumber('+1917#######');
    const periodEnd = makePeriodEnd();
    const outboundMessageCount = Math.round(Math.random() * 5 + 3);

    const testRunResults = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const sendingLocation = await setUpSendingLocation(client, fromNumber);
        const { id: sendingLocationId, profile_id: profileId } =
          sendingLocation;

        const { totalSegments: outboundSegments } =
          await insertOutboundMessages({
            client,
            fromNumber,
            periodEnd,
            profileId,
            sendingLocationId,
            count: outboundMessageCount,
            intervalMinutes: 30,
          });

        // Insert usage before period
        const outsidePeriodEnd = new Date(periodEnd.getTime());
        outsidePeriodEnd.setHours(outsidePeriodEnd.getHours() - 3);
        await insertOutboundMessages({
          client,
          fromNumber,
          profileId,
          sendingLocationId,
          count: 5,
          intervalMinutes: 30,
          periodEnd: outsidePeriodEnd,
        });

        // Insert usage after period
        outsidePeriodEnd.setHours(outsidePeriodEnd.getHours() + 6);
        await insertOutboundMessages({
          client,
          fromNumber,
          profileId,
          sendingLocationId,
          count: 5,
          intervalMinutes: 30,
          periodEnd: outsidePeriodEnd,
        });

        await generateRollups({ client, periodEnd });

        const {
          rows: [report],
        } = await client.query<MessagingUsageRollupRow>(
          `select * from billing.messaging_usage_rollups where profile_id = $1 and period_end = $2`,
          [profileId, periodEnd]
        );

        return { outboundSegments, report };
      }
    );

    expect(testRunResults.report.outbound_sms_messages).toEqual(
      outboundMessageCount
    );
    expect(testRunResults.report.outbound_sms_segments).toEqual(
      testRunResults.outboundSegments
    );
    expect(testRunResults.report.outbound_mms_messages).toEqual(0);
    expect(testRunResults.report.outbound_mms_segments).toEqual(0);
    expect(testRunResults.report.inbound_mms_messages).toEqual(0);
    expect(testRunResults.report.inbound_mms_segments).toEqual(0);
  });
});
