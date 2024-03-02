import faker from 'faker';
import { Pool } from 'pg';

import config from '../../config';
import { ProfileRecord, Service } from '../../lib/types';
import {
  createClient,
  createProfile,
  createSendingAccount,
  createSendingLocation,
} from '../fixtures';
import { autoRollbackMiddleware, withPgMiddlewares } from '../helpers';

describe('management of grey-route provisioned status', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('inserts grey-route profiles with provisioned = false default', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { clientId } = await createClient(client, {});
      const sendingAccount = await createSendingAccount(client, {
        service: Service.Telnyx,
        triggers: true,
      });
      const {
        rows: [profile],
      } = await client.query<ProfileRecord>(
        `
          insert into sms.profiles (client_id, sending_account_id, channel, display_name, reply_webhook_url, message_status_webhook_url)
          values ($1, $2, $3, $4, $5, $6)
          returning *
        `,
        [
          clientId,
          sendingAccount.id,
          'grey-route',
          faker.company.companyName(),
          faker.internet.url(),
          faker.internet.url(),
        ]
      );

      expect(profile.provisioned).toBe(false);
    });
  });

  it('manages single-sending location lifecycle', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      let profile = await createProfile(client, {
        client: { type: 'create' },
        sending_account: {
          service: Service.Telnyx,
          triggers: true,
          type: 'create',
        },
        profile_service_configuration: {
          type: 'create',
          profile_service_configuration_id: faker.random.uuid(),
        },
        triggers: true,
      });

      const getProfile = () =>
        client
          .query<ProfileRecord>(`select * from sms.profiles where id = $1`, [
            profile.id,
          ])
          .then(({ rows }) => rows[0]);

      expect(profile.provisioned).toBe(false);

      const sendingLocation = await createSendingLocation(client, {
        center: '11238',
        profile: { type: 'existing', id: profile.id },
        triggers: true,
      });

      profile = await getProfile();
      expect(profile.provisioned).toBe(true);

      await client.query(
        `update sms.sending_locations set decomissioned_at = now() where id = $1`,
        [sendingLocation.id]
      );

      profile = await getProfile();
      expect(profile.provisioned).toBe(false);
    });
  });

  it('manages multi-sending location lifecycle', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      let profile = await createProfile(client, {
        client: { type: 'create' },
        sending_account: {
          service: Service.Telnyx,
          triggers: true,
          type: 'create',
        },
        profile_service_configuration: {
          type: 'create',
          profile_service_configuration_id: faker.random.uuid(),
        },
        triggers: true,
      });

      const getProfile = () =>
        client
          .query<ProfileRecord>(`select * from sms.profiles where id = $1`, [
            profile.id,
          ])
          .then(({ rows }) => rows[0]);

      expect(profile.provisioned).toBe(false);

      const sendingLocations = await Promise.all(
        [...Array(2)].map((_) =>
          createSendingLocation(client, {
            center: '11238',
            profile: { type: 'existing', id: profile.id },
            triggers: true,
          })
        )
      );

      profile = await getProfile();
      expect(profile.provisioned).toBe(true);

      await client.query(
        `update sms.sending_locations set decomissioned_at = now() where id = $1`,
        [sendingLocations[0].id]
      );

      profile = await getProfile();
      expect(profile.provisioned).toBe(true);

      await client.query(
        `update sms.sending_locations set decomissioned_at = now() where id = $1`,
        [sendingLocations[1].id]
      );

      profile = await getProfile();
      expect(profile.provisioned).toBe(false);

      await createSendingLocation(client, {
        center: '11238',
        profile: { type: 'existing', id: profile.id },
        triggers: true,
      });

      profile = await getProfile();
      expect(profile.provisioned).toBe(true);
    });
  });
});
