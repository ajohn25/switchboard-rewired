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
import { fakeNumber, findGraphileWorkerJob } from '../__tests__/numbers/utils';
import config from '../config';
import { Service } from '../lib/types';
import {
  SELL_NUMBER_IDENTIFIER,
  sellNumber,
  SellNumberPayload,
} from './sell-number';

const setUpSellNumber = async (client: PoolClient, service: Service) => {
  const sendingAccount = await createSendingAccount(client, {
    triggers: true,
    service,
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

  return {
    sendingAccountId: sendingAccount.id,
    profileId: sendingLocation.profile_id,
    sendingLocationId: sendingLocation.id,
  };
};

describe('sell number', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('sell twilio number', async () => {
    const soldNumber = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingLocationId } = await setUpSellNumber(
          client,
          Service.Twilio
        );
        const fromNumber = fakeNumber();

        const { rows } = await client.query(
          'insert into sms.all_phone_numbers (phone_number, sending_location_id) values ($1, $2) returning *',
          [fromNumber, sendingLocationId]
        );

        const [{ id: phoneNumberId }] = rows;

        await client.query(
          'update sms.all_phone_numbers set released_at = now() where id = $1',
          [phoneNumberId]
        );

        const job = await findGraphileWorkerJob(
          client,
          SELL_NUMBER_IDENTIFIER,
          'id',
          phoneNumberId
        );

        TwilioNock.getPhoneNumberId({});
        TwilioNock.deleteNumber();

        await sellNumber(client, job.payload as SellNumberPayload);

        const {
          rows: [updatedNumber],
        } = await client.query(
          'select * from sms.all_phone_numbers where id = $1',
          [phoneNumberId]
        );

        return updatedNumber;
      }
    );

    expect(soldNumber).not.toBeNull();
    expect(soldNumber).toHaveProperty('sold_at');
    expect(soldNumber.sold_at).not.toBeNull();
  });

  test('sell telnyx number', async () => {
    const soldNumber = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingLocationId } = await setUpSellNumber(
          client,
          Service.Telnyx
        );
        const fromNumber = fakeNumber();

        const { rows } = await client.query(
          'insert into sms.all_phone_numbers (phone_number, sending_location_id) values ($1, $2) returning *',
          [fromNumber, sendingLocationId]
        );

        const [{ id: phoneNumberId }] = rows;

        await client.query(
          'update sms.all_phone_numbers set released_at = now() where id = $1',
          [phoneNumberId]
        );

        const job = await findGraphileWorkerJob(
          client,
          SELL_NUMBER_IDENTIFIER,
          'id',
          phoneNumberId
        );

        TelnyxNock.getPhoneNumbers([fromNumber]);
        TelnyxNock.deletePhoneNumber(200);
        TelnyxNock.deletePhoneNumber(404);

        await sellNumber(client, job.payload as SellNumberPayload);

        const {
          rows: [updatedNumber],
        } = await client.query(
          'select * from sms.all_phone_numbers where id = $1',
          [phoneNumberId]
        );

        return updatedNumber;
      }
    );

    expect(soldNumber).not.toBeNull();
    expect(soldNumber).toHaveProperty('sold_at');
    expect(soldNumber.sold_at).not.toBeNull();
  });

  test('sell bandwidth number', async () => {
    const soldNumber = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { sendingLocationId } = await setUpSellNumber(
          client,
          Service.Bandwidth
        );
        const fromNumber = fakeNumber();

        const { rows } = await client.query(
          'insert into sms.all_phone_numbers (phone_number, sending_location_id) values ($1, $2) returning *',
          [fromNumber, sendingLocationId]
        );

        const [{ id: phoneNumberId }] = rows;

        await client.query(
          'update sms.all_phone_numbers set released_at = now() where id = $1',
          [phoneNumberId]
        );

        const job = await findGraphileWorkerJob(
          client,
          SELL_NUMBER_IDENTIFIER,
          'id',
          phoneNumberId
        );

        BandwidthNock.disconnectPhoneNumber({ orderStatus: 'RECIEVED' });

        await sellNumber(client, job.payload as SellNumberPayload);

        const {
          rows: [updatedNumber],
        } = await client.query(
          'select * from sms.all_phone_numbers where id = $1',
          [phoneNumberId]
        );

        return updatedNumber;
      }
    );

    expect(soldNumber).not.toBeNull();
    expect(soldNumber).toHaveProperty('sold_at');
    expect(soldNumber.sold_at).not.toBeNull();
  });
});
