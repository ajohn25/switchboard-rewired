import { Pool } from 'pg';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import config from '../config';

import { createSendingLocation } from '../__tests__/fixtures';
import { Service } from './types';
import { doesLivePhoneNumberExist } from './utils';

describe('doesLivePhoneNumberExist', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('should detect an existing live number', async () => {
    const phone = '+16463893770';

    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const sendingLocation = await createSendingLocation(client, {
        center: '11205',
        triggers: true,
        profile: { type: 'fast', service: Service.Telnyx },
      });
      await client.query(
        `insert into sms.all_phone_numbers (phone_number, sending_location_id) values ($1, $2);`,
        [phone, sendingLocation.id]
      );
      const result = await doesLivePhoneNumberExist(client, phone);
      expect(result).toBe(true);
    });
  });

  it('should not detect a decomissioned number', async () => {
    const phone = '+16463893770';

    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const sendingLocation = await createSendingLocation(client, {
        center: '11205',
        triggers: true,
        profile: { type: 'fast', service: Service.Telnyx },
      });
      await client.query(
        `insert into sms.all_phone_numbers (phone_number, sending_location_id, released_at) values ($1, $2, now());`,
        [phone, sendingLocation.id]
      );
      const result = await doesLivePhoneNumberExist(client, phone);
      expect(result).toBe(false);
    });
  });
});
