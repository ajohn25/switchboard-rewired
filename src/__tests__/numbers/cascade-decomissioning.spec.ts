import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import config from '../../config';
import { SELL_NUMBER_IDENTIFIER } from '../../jobs/sell-number';
import { Service } from '../../lib/types';
import { createSendingLocation } from '../fixtures';
import { autoRollbackMiddleware, withPgMiddlewares } from '../helpers';
import { fakeNumber, findJob } from './utils';

const setUpCascadeTest = async (client: PoolClient) => {
  const { id: sendingLocationId } = await createSendingLocation(client, {
    center: '11238',
    triggers: true,
    profile: {
      type: 'create',
      triggers: true,
      client: { type: 'create' },
      sending_account: {
        type: 'create',
        triggers: true,
        service: Service.Telnyx,
      },
      profile_service_configuration: {
        type: 'create',
        profile_service_configuration_id: faker.random.uuid(),
      },
    },
  });
  return sendingLocationId;
};

describe('cascade sending location decomissions', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('it should mark phone numbers with released_at and they should not be in the view', async () => {
    const [releasedNumbers, numbersLeft] = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const sendingLocationId = await setUpCascadeTest(client);
        const fromNumber = fakeNumber();

        await client.query(
          'insert into sms.phone_numbers (phone_number, sending_location_id) values ($1, $2) returning *',
          [fromNumber, sendingLocationId]
        );

        await client.query(
          'update sms.sending_locations set decomissioned_at = now() where id = $1',
          [sendingLocationId]
        );

        const {
          rows: [{ count: countOfPhoneNumbersWithReleasedAt }],
        } = await client.query(
          'select count(*) as count from sms.all_phone_numbers where released_at is not null and sending_location_id = $1',
          [sendingLocationId]
        );

        const {
          rows: [{ count: countOfPhoneNumbersInView }],
        } = await client.query(
          'select count(*) as count from sms.phone_numbers where sending_location_id = $1',
          [sendingLocationId]
        );

        return [countOfPhoneNumbersWithReleasedAt, countOfPhoneNumbersInView];
      }
    );

    expect(releasedNumbers).toBe('1');
    expect(numbersLeft).toBe('0');
  });

  test('there should be a job to decomission the numbers', async () => {
    const foundJob = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const sendingLocationId = await setUpCascadeTest(client);
        const fromNumber = fakeNumber();

        await client.query(
          'insert into sms.phone_numbers (phone_number, sending_location_id) values ($1, $2) returning *',
          [fromNumber, sendingLocationId]
        );

        await client.query(
          'update sms.sending_locations set decomissioned_at = now() where id = $1',
          [sendingLocationId]
        );

        const job = await findJob(
          client,
          SELL_NUMBER_IDENTIFIER,
          'phone_number',
          fromNumber
        );

        return job;
      }
    );

    expect(foundJob).not.toBeNull();
  });
});
