import faker from 'faker';
import { Pool, PoolClient } from 'pg';
import { default as ql } from 'superagent-graphql';
import supertest from 'supertest';

import {
  createPhoneNumberRequest,
  createProfile,
  createSendingAccount,
  createSendingLocation,
  createTenDlcCampaign,
} from '../../__tests__/fixtures';
import { TollFreeUnion } from '../../__tests__/fixtures/profile';
import { createTollFreeUseCase } from '../../__tests__/fixtures/toll-free-use-case';
import app from '../../app';
import config from '../../config';
import { withClient } from '../../lib/db';
import { Service, TrafficChannel } from '../../lib/types';

/**
 * Set up profile record with pre-set boilerplate to improve test case readability below
 * @param client Postgres PoolClient to use
 * @param options options for traffic channel-specific setup
 * @param sendingAccountId optional sending account to use for profile setup
 * @returns a profile database record
 */
const setUpProfile = async (
  client: PoolClient,
  options: TollFreeUnion,
  sendingAccountId?: string
) => {
  const saId =
    sendingAccountId ??
    (
      await createSendingAccount(client, {
        triggers: true,
        service: Service.Bandwidth,
      })
    ).id;

  const profile = await createProfile(client, {
    triggers: true,
    client: { type: 'existing', id: clientId },
    sending_account: { type: 'existing', id: saId },
    profile_service_configuration: {
      type: 'create',
      profile_service_configuration_id: faker.random.uuid(),
    },
    ...options,
  });

  return profile;
};

const CREATE_SENDING_LOCATION_QUERY = `
  mutation CreateSendingLocation($profileId: UUID!, $center: ZipCode!, $referenceName: String!) {
    createSendingLocation(input: {sendingLocation: {profileId: $profileId, center: $center, referenceName: $referenceName, purchasingStrategy: SAME_STATE_BY_DISTANCE}}) {
      sendingLocation {
        id
      }
    }
  }
`;

interface CreateSendingLocationVariables {
  profileId: string;
  center: string;
  referenceName: string;
}

/**
 * Utility for forming correct GraphQL mutation
 * @param variables GraphQL mutation variables
 * @returns superagent/supertest middleware for GraphQL mutation
 */
const generateQuery = (variables: CreateSendingLocationVariables) =>
  ql(CREATE_SENDING_LOCATION_QUERY, variables);

/**
 * Wrap mocking a createSendingLocation mutation for better test case readability below
 * @param profileId the ID of the profile to set the sending location up on
 * @returns HTTP request response
 */
const runCreateSendingLocation = (profileId: string) =>
  supertest(app)
    .post('/sms/graphql')
    .set('token', token)
    .use(
      generateQuery({
        profileId,
        center: '11238',
        referenceName: faker.company.companyName(),
      })
    );

let pool: Pool;
let token: string;
let clientId: string;

beforeAll(async () => {
  pool = new Pool({ connectionString: config.databaseUrl });

  const { client_id, access_token } = await supertest(app)
    .post('/admin/register')
    .set('token', config.adminAccessToken)
    .send({ name: faker.company.companyName() })
    .then((response) => response.body);

  token = access_token;
  clientId = client_id;
});

afterAll(() => {
  return pool.end();
});

describe('ProvisionSendingLocations', () => {
  it('does not create phone number request for grey-route channel', async () =>
    withClient(pool, async (client) => {
      const profile = await setUpProfile(client, {
        channel: TrafficChannel.GreyRoute,
      });

      const response = await runCreateSendingLocation(profile.id);

      expect(response.status).toBe(200);
      expect(response.body.errors).toBeFalsy();
      expect(response.body.data.createSendingLocation).not.toBeNull();

      const sendingLocationId =
        response.body.data.createSendingLocation.sendingLocation.id;

      const { rowCount } = await client.query(
        `select 1 from sms.phone_number_requests where sending_location_id = $1`,
        [sendingLocationId]
      );

      expect(rowCount).toBe(0);
    }));

  it('throws an error for toll-free channel', async () =>
    withClient(pool, async (client) => {
      const sendingAccount = await createSendingAccount(client, {
        triggers: true,
        service: Service.Bandwidth,
      });

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

      const profile = await setUpProfile(
        client,
        {
          channel: TrafficChannel.TollFree,
          tollFreeUseCaseId: tollFreeUseCase.id,
        },
        sendingAccount.id
      );

      const response = await runCreateSendingLocation(profile.id);

      expect(response.status).toBe(200);
      expect(response.body.data.createSendingLocation).toBeNull();
      expect(response.body.errors).not.toBeNull();
      expect(response.body.errors).toHaveLength(1);
      expect(response.body.errors[0].path).toHaveLength(1);
      expect(response.body.errors[0].path[0]).toBe('createSendingLocation');
      expect(response.body.errors[0].message).toBe(
        'Cannot create ad hoc sending location for toll-free profile!'
      );

      const { rowCount } = await client.query(
        `select 1 from sms.sending_locations where profile_id = $1`,
        [profile.id]
      );

      expect(rowCount).toBe(0);
    }));

  it('creates a phone number request for 10dlc channel IFF below capacity', async () =>
    withClient(pool, async (client) => {
      const sendingAccount = await createSendingAccount(client, {
        triggers: true,
        service: Service.Bandwidth,
      });
      const tenDlcCampaign = await createTenDlcCampaign(client, {
        registrarSendingAccountId: sendingAccount.id,
        registrarCampaignId: faker.random.uuid(),
      });
      const profile = await setUpProfile(
        client,
        {
          channel: TrafficChannel.TenDlc,
          tenDlcCampaignId: tenDlcCampaign.campaignId,
        },
        sendingAccount.id
      );

      const response = await runCreateSendingLocation(profile.id);

      expect(response.status).toBe(200);
      expect(response.body.errors).toBeFalsy();
      expect(response.body.data.createSendingLocation).not.toBeNull();

      const sendingLocationId =
        response.body.data.createSendingLocation.sendingLocation.id;

      const { rowCount } = await client.query(
        `select 1 from sms.phone_number_requests where sending_location_id = $1`,
        [sendingLocationId]
      );

      expect(rowCount).toBe(1);
    }));

  it('throws an error for 10dlc channel IFF at or above capacity', async () =>
    withClient(pool, async (client) => {
      const sendingAccount = await createSendingAccount(client, {
        triggers: true,
        service: Service.Bandwidth,
      });
      const tenDlcCampaign = await createTenDlcCampaign(client, {
        registrarSendingAccountId: sendingAccount.id,
        registrarCampaignId: faker.random.uuid(),
      });
      const profile = await setUpProfile(
        client,
        {
          channel: TrafficChannel.TenDlc,
          tenDlcCampaignId: tenDlcCampaign.campaignId,
        },
        sendingAccount.id
      );

      const existingSendingLocation = await createSendingLocation(client, {
        triggers: true,
        profile: { type: 'existing', id: profile.id },
        center: '11238',
      });

      // The pg library appears to have trouble with the `area_code` custom PG domain:
      // `sms.sending_locations.area_codes` is returned above as a string instead of a three-element array
      // so we use our own value instead
      const areaCode = '347';

      await Promise.all(
        [...Array(49)].map((_) =>
          createPhoneNumberRequest(client, {
            triggers: false,
            sending_location: {
              type: 'existing',
              id: existingSendingLocation.id,
            },
            area_code: areaCode,
          })
        )
      );

      const response = await runCreateSendingLocation(profile.id);

      expect(response.status).toBe(200);
      expect(response.body.data.createSendingLocation).toBeNull();
      expect(response.body.errors).not.toBeNull();
      expect(response.body.errors).toHaveLength(1);
      expect(response.body.errors[0].path).toHaveLength(1);
      expect(response.body.errors[0].path[0]).toBe('createSendingLocation');
      expect(response.body.errors[0].message).toBe(
        'Expected 1 new phone number request for 10DLC profile but got 0. The 10DLC campaign connected to this profile may be at its active phone number limit.'
      );

      const { rowCount } = await client.query(
        `select 1 from sms.sending_locations where profile_id = $1`,
        [profile.id]
      );

      // Just the existingSendingLocation
      expect(rowCount).toBe(1);
    }));
});
