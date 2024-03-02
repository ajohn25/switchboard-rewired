import faker from 'faker';
import nock from 'nock';
import { Pool } from 'pg';
import supertest from 'supertest';

import { RegisterPayload } from '../../apis/admin';
import app from '../../app';
import config from '../../config';
import { withClient } from '../../lib/db';
import { Service } from '../../lib/types';
import { createSendingAccount } from '../fixtures';
import { TELNYX_V2_API_URL } from '../nocks/telnyx/constants';

const clientName = `${faker.name.findName()} ${faker.random.word()}`;

describe('register endpoint', () => {
  let pool: Pool;
  let sendingAccountId: string;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });

    return withClient(pool, async (client) => {
      const sendingAccount = await createSendingAccount(client, {
        service: Service.Telnyx,
        triggers: true,
      });
      sendingAccountId = sendingAccount.id;
      await client.query(
        `update sms.sending_accounts set display_name = 'Default' where id = $1`,
        [sendingAccount.id]
      );
    });
  });

  afterAll(() => {
    return pool.end();
  });

  test('POST /register should error if profile is malformed', async () => {
    const payload = {
      name: clientName,
      profiles: [
        {
          message_status_webhook_url: faker.internet.url(),
        },
      ],
    };

    const response = await supertest(app)
      .post('/admin/register')
      .set('token', config.adminAccessToken)
      .send(payload);

    expect(response.status).toBe(400);
    expect(response.body).toHaveProperty('errors');
    expect(response.body.errors[0]).toBe(
      "profile 0 missing 'reply_webhook_url'"
    );
  });

  test('POST /register should return the access token and profile id', async () => {
    const payload: RegisterPayload = {
      name: clientName,
      profiles: [
        {
          message_status_webhook_url: faker.internet.url(),
          reply_webhook_url: faker.internet.url(),
          sending_locations: [],
          template_sending_account_id: sendingAccountId,
        },
      ],
    };

    nock(TELNYX_V2_API_URL)
      .post(new RegExp('/messaging_profiles'))
      .times((payload.profiles ?? []).length)
      .reply(200, {
        data: {
          created_at: new Date().toISOString(),
          enabled: true,
          id: '3fa85f64-5717-4562-b3fc-2c963f66afa6',
          name: payload.name,
          number_pool_settings: null,
          record_type: 'messaging_profile',
          updated_at: new Date().toISOString(),
          url_shortener_settings: null,
          v1_secret: 'rP1VamejkU2v0qIUxntqLW2c',
          webhook_api_version: '2',
          webhook_failover_url: '',
          webhook_url: 'https://www.example.com/hooks',
          whitelisted_destinations: ['US'],
        },
      });

    const response = await supertest(app)
      .post('/admin/register')
      .set('token', config.adminAccessToken)
      .send(payload);

    expect(response.body).toHaveProperty('access_token');
    expect(response.body).toHaveProperty('profile_ids');
    expect(typeof response.body.profile_ids[0]).toEqual('string');
  });
});
