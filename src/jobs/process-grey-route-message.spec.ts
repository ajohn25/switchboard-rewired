import faker from 'faker';
import RedisMock from 'ioredis-mock';
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
import {
  fakeNumber,
  findJob,
  setClientIdConfig,
} from '../__tests__/numbers/utils';
import config from '../config';
import { ProcessMessagePayload } from '../lib/process-message';
import { defineCustomRedisCommands } from '../lib/redis';
import { Service } from '../lib/types';
import {
  PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
  processGreyRouteMessage,
} from './process-grey-route-message';

const setUpProcessMessage = async (client: PoolClient, fromNumber: string) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service: Service.Telnyx,
  });

  const { clientId } = await createClient(client, {});

  const sendingLocation = await createSendingLocation(client, {
    center: '10001',
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

describe('process message', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('it should queue a job that processes the message and returns the processed message', async () => {
    const m = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const fromNumber = fakeNumber();
        const toNumber = fakeNumber();

        const { profileId } = await setUpProcessMessage(client, fromNumber);

        // insert message to process
        const {
          rows: [message],
        } = await client.query(
          'select id from sms.send_message($1, $2, $3, $4, $5)',
          [profileId, toNumber, faker.hacker.phrase(), null, '11238']
        );

        const foundProcessMessageJob = await findJob<ProcessMessagePayload>(
          client,
          PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
          'id',
          message.id
        );

        // run process message
        const result = await processGreyRouteMessage(
          client,
          foundProcessMessageJob.payload as ProcessMessagePayload,
          defineCustomRedisCommands(new RedisMock())
        );

        return result;
      }
    );

    expect(m.sending_location_id).not.toBeNull();

    const routedProof =
      'from_number' in m
        ? m.pending_number_request_id || m.from_number
        : m.pending_number_request_id;

    expect(routedProof).toBeTruthy();
  });
});
