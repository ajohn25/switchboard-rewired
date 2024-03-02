import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import {
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { BandwidthNock, TelnyxNock, TwilioNock } from '../__tests__/nocks';
import { findJob, Job } from '../__tests__/numbers/utils';
import config from '../config';
import { PoolOrPoolClient, sql } from '../db';
import { SendingLocationPurchasingStrategy, Service } from '../lib/types';
import {
  ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
  estimateAreaCodeCapacity,
  EstimateAreaCodeCapacityPayload,
} from './estimate-area-code-capacity';

const setUpEstimateAreaCodeCapacity = async (
  client: PoolClient,
  service: Service
): Promise<{ sendingAccountId: string; sendingLocationId: string }> => {
  const sendingAccount = await createSendingAccount(client, {
    service,
    triggers: true,
  });
  const sendingLocation = await createSendingLocation(client, {
    center: '11205',
    purchasing_strategy: SendingLocationPurchasingStrategy.ExactAreaCodes,
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

  return {
    sendingAccountId: sendingAccount.id,
    sendingLocationId: sendingLocation.id,
  };
};

export const findAreaCodeEstimateJob = async (
  client: PoolOrPoolClient,
  sendingLocationId: string,
  areaCode: string
) => {
  const query = sql`
    select jobs.*, tasks.identifier as task_identifier
    from graphile_worker.jobs
    join graphile_worker.tasks on jobs.task_id = tasks.id
    where
      tasks.identifier = ${ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER}
      and payload::jsonb->>'sending_location_id' = ${sendingLocationId}
      and payload::jsonb->>'area_code' = ${areaCode}
  `;

  const { rows } = await client.query(query.sql, [...query.values]);
  return rows[0];
};

describe('estimate area code capacities', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('should estimate Telnyx capacities', async () => {
    const targetCapacity = faker.random.number(50);
    const actualCapacity = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingAccountId, sendingLocationId } =
          await setUpEstimateAreaCodeCapacity(client, Service.Telnyx);

        const queuedJob = await findJob(
          client,
          ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
          'id',
          sendingLocationId
        );

        const { area_codes } = queuedJob.payload;

        TelnyxNock.getAvailableNumbers({
          targetCapacity,
          times: area_codes.length,
          using: 'times',
        });

        await estimateAreaCodeCapacity(
          client,
          queuedJob.payload as EstimateAreaCodeCapacityPayload
        );

        const {
          rows: [{ capacity }],
        } = await client.query(
          `
            select capacity from sms.area_code_capacities
            where sending_account_id = $1 and area_code = $2;
          `,
          [sendingAccountId, area_codes[0]]
        );
        return capacity;
      }
    );

    expect(actualCapacity).toEqual(targetCapacity);
  });

  test('should estimate Twilio capacities', async () => {
    const targetCapacity = faker.random.number(50);
    const actualCapacity = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingAccountId, sendingLocationId } =
          await setUpEstimateAreaCodeCapacity(client, Service.Twilio);

        const queuedJob = await findJob(
          client,
          ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
          'id',
          sendingLocationId
        );

        const { area_codes } = queuedJob.payload;

        TwilioNock.getNumberAvailability(area_codes.length, targetCapacity);

        await estimateAreaCodeCapacity(
          client,
          queuedJob.payload as EstimateAreaCodeCapacityPayload
        );

        const {
          rows: [{ capacity }],
        } = await client.query(
          `
              select capacity from sms.area_code_capacities
              where sending_account_id = $1 and area_code = $2;
            `,
          [sendingAccountId, area_codes[0]]
        );
        return capacity;
      }
    );

    expect(actualCapacity).toEqual(targetCapacity);
  });

  test('should estimate Bandwidth capacities', async () => {
    const targetCapacity = faker.random.number(50);
    const actualCapacity = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingAccountId, sendingLocationId } =
          await setUpEstimateAreaCodeCapacity(client, Service.Bandwidth);

        const queuedJob = await findJob(
          client,
          ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
          'id',
          sendingLocationId
        );

        const { area_codes } = queuedJob.payload;

        BandwidthNock.getAvailableNumbers({
          targetCapacity,
          times: area_codes.length,
          using: 'times',
        });

        await estimateAreaCodeCapacity(
          client,
          queuedJob.payload as EstimateAreaCodeCapacityPayload
        );

        const {
          rows: [{ capacity }],
        } = await client.query(
          `
              select capacity from sms.area_code_capacities
              where sending_account_id = $1 and area_code = $2;
            `,
          [sendingAccountId, area_codes[0]]
        );
        return capacity;
      }
    );

    expect(actualCapacity).toEqual(targetCapacity);
  });
});
