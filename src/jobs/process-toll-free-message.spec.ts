import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import {
  createClient,
  createPhoneNumber,
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import { createTollFreeUseCase } from '../__tests__/fixtures/toll-free-use-case';
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
import { Service, TrafficChannel } from '../lib/types';
import {
  PROCESS_TOLL_FREE_MESSAGE_IDENTIFIER,
  processTollFreeMessage,
} from './process-toll-free-message';

const setUpProcessMessage = async (client: PoolClient, fromNumber: string) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service: Service.Bandwidth,
  });

  const { clientId } = await createClient(client, {});

  const tollFreeUseCase = await createTollFreeUseCase(client, {
    triggers: true,
    client_id: clientId,
    sending_account_id: sendingAccount.id,
    area_code: '877',
    phone_number_id: null,
    stakeholders: 'dev@politicsrewired.com',
    submitted_at: new Date().toISOString(),
    approved_at: null,
    throughput_interval: null,
    throughput_limit: null,
  });

  const sendingLocation = await createSendingLocation(client, {
    center: '10001',
    triggers: true,
    profile: {
      type: 'create',
      channel: TrafficChannel.TollFree,
      triggers: true,
      client: { type: 'existing', id: clientId },
      sending_account: { type: 'existing', id: sendingAccount.id },
      profile_service_configuration: {
        type: 'create',
        profile_service_configuration_id: faker.random.uuid(),
      },
      tollFreeUseCaseId: tollFreeUseCase.id,
    },
  });

  const phoneNumber = await createPhoneNumber(client, {
    sending_location_id: sendingLocation.id,
    phone_number: fromNumber,
  });

  await client.query(
    `
      update sms.toll_free_use_cases
      set
          approved_at = now()
        , phone_number_id = $2
      where id = $1
    `,
    [tollFreeUseCase.id, phoneNumber.id]
  );

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
    const fromNumber = fakeNumber('877');
    const toNumber = fakeNumber();

    const m = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
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
          PROCESS_TOLL_FREE_MESSAGE_IDENTIFIER,
          'id',
          message.id
        );

        // run process message
        const result = await processTollFreeMessage(
          client,
          foundProcessMessageJob.payload
        );

        return result;
      }
    );

    expect(m.stage).toBe('queued');
    expect(m.sending_location_id).not.toBeNull();
    expect(m.from_number).toBe(fromNumber);
  });
});
