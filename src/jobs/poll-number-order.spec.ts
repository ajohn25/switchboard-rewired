import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import { createPhoneNumberRequest, createProfile } from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { BandwidthNock, TelnyxNock } from '../__tests__/nocks';
import { findJob } from '../__tests__/numbers/utils';
import config from '../config';
import {
  PhoneNumberRequestRecord,
  Service,
  TrafficChannel,
} from '../lib/types';
import {
  POLL_NUMBER_ORDER_IDENTIFIER,
  pollNumberOrder,
  PollNumberOrderPayload,
} from './poll-number-order';
import { PURCHASE_NUMBER_IDENTIFIER } from './purchase-number';
import { queueNextStepAsIfJobRan } from './queue-next-step-in-purchase-number-pipeline';

const setUpNumberRequest = async (
  client: PoolClient,
  options: {
    service: Service;
    profileServiceConfigId: string | null;
    service10DlcCampaign: string | null;
  }
) => {
  const profile = await createProfile(client, {
    client: { type: 'create' },
    sending_account: {
      service: options.service,
      triggers: true,
      type: 'create',
    },
    ...(options.service10DlcCampaign
      ? {
          channel: TrafficChannel.TenDlc,
          tenDlcCampaign: { registrarCampaignId: options.service10DlcCampaign },
        }
      : { channel: TrafficChannel.GreyRoute }),
    profile_service_configuration: {
      type: 'create',
      profile_service_configuration_id: options.profileServiceConfigId,
    },
    triggers: true,
  });
  const request = await createPhoneNumberRequest(client, {
    area_code: '646',
    phone_number: null,
    sending_location: {
      center: '11238',
      profile: { type: 'existing', id: profile.id },
      triggers: true,
      type: 'create',
    },
    service_order_id: null,
    triggers: true,
  });

  await client.query(
    `
      update sms.phone_number_requests
      set
        phone_number = '+16463893770',
        service_order_id = $1
      where id = $2
    `,
    [faker.random.uuid(), request.id]
  );

  await queueNextStepAsIfJobRan(
    client,
    profile.sending_account_id,
    profile.id,
    PURCHASE_NUMBER_IDENTIFIER,
    request.id
  );

  const job = await findJob<PollNumberOrderPayload>(
    client,
    POLL_NUMBER_ORDER_IDENTIFIER,
    'id',
    request.id
  );

  const getRequest = async () => {
    const { rows } = await client.query<PhoneNumberRequestRecord>(
      `select * from sms.phone_number_requests where id = $1`,
      [request.id]
    );
    return rows[0];
  };

  return { request, profile, job, getRequest };
};

describe('poll telnyx number order', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('should create job for non-10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Telnyx,
        service10DlcCampaign: null,
        profileServiceConfigId: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(POLL_NUMBER_ORDER_IDENTIFIER);
    });
  });

  it('should create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Telnyx,
        service10DlcCampaign: faker.random.uuid(),
        profileServiceConfigId: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(POLL_NUMBER_ORDER_IDENTIFIER);
    });
  });

  it('should poll number order', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const serviceProfileId = faker.random.uuid();
      const { getRequest, job } = await setUpNumberRequest(client, {
        profileServiceConfigId: serviceProfileId,
        service: Service.Telnyx,
        service10DlcCampaign: null,
      });

      TelnyxNock.getNumberOrder({
        serviceProfileId,
        phoneNumbers: ['+16463893770'],
        status: 'success',
      });

      await pollNumberOrder(client, job.payload);

      const finalRequest = await getRequest();
      expect(finalRequest.service_order_completed_at).toBeDefined();
    });
  });
});

describe('poll twilio number order', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('should NOT create job for non-10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Twilio,
        service10DlcCampaign: null,
        profileServiceConfigId: faker.random.uuid(),
      });

      expect(job).toBeUndefined();
    });
  });

  it('should NOT create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Twilio,
        service10DlcCampaign: faker.random.uuid(),
        profileServiceConfigId: faker.random.uuid(),
      });

      expect(job).toBeUndefined();
    });
  });
});

describe('poll bandwidth number order', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('should create job for non-10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Bandwidth,
        service10DlcCampaign: null,
        profileServiceConfigId: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(POLL_NUMBER_ORDER_IDENTIFIER);
    });
  });

  it('should poll number order', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { getRequest, job } = await setUpNumberRequest(client, {
        service: Service.Bandwidth,
        service10DlcCampaign: null,
        profileServiceConfigId: faker.random.uuid(),
      });

      BandwidthNock.getNumberOrder({
        phoneNumbers: ['+16463893770'],
        status: 'COMPLETE',
      });

      await pollNumberOrder(client, job.payload);

      const finalRequest = await getRequest();
      expect(finalRequest.service_order_completed_at).toBeDefined();
    });
  });
});
