import faker from 'faker';
import { Pool } from 'pg';

import { createSendingLocation } from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { TelnyxNock } from '../__tests__/nocks';
import { findGraphileWorkerJob } from '../__tests__/numbers/utils';
import config from '../config';
import { PhoneNumberRecord, Service } from '../lib/types';
import {
  ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER,
  associateServiceProfileToNumber,
} from './associate-service-profile-to-phone-number';

describe('associate telnyx messaging profile', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('associates telnyx profile successfully for non-10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const serviceProfileId = faker.random.uuid();
      const sendingLocation = await createSendingLocation(client, {
        center: '11238',
        profile: {
          type: 'create',
          client: { type: 'create' },
          sending_account: {
            type: 'create',
            service: Service.Telnyx,
            triggers: true,
          },
          triggers: true,
          profile_service_configuration: {
            type: 'create',
            profile_service_configuration_id: serviceProfileId,
          },
        },
        triggers: true,
      });

      const phoneNumber = faker.phone.phoneNumber('+1##########');
      await client.query(
        `insert into sms.all_phone_numbers (sending_location_id, phone_number) values ($1, $2)`,
        [sendingLocation.id, phoneNumber]
      );

      await client.query(
        `select graphile_worker.add_job($1, $2, max_attempts := 6, job_key := $3)`,
        [
          ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER,
          { phone_number: phoneNumber },
          phoneNumber,
        ]
      );

      const job = await findGraphileWorkerJob(
        client,
        ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER,
        'phone_number',
        phoneNumber
      );

      TelnyxNock.setMessagingProfile();

      const result = await associateServiceProfileToNumber(client, job.payload);
      expect(result).toEqual(serviceProfileId);
    });
  });
});
