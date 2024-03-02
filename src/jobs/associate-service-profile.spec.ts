import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import { createPhoneNumberRequest, createProfile } from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { TelnyxNock } from '../__tests__/nocks';
import { fakeSid } from '../__tests__/nocks/twilio/utils';
import { findJob } from '../__tests__/numbers/utils';
import config from '../config';
import {
  PhoneNumberRequestRecord,
  Service,
  TrafficChannel,
} from '../lib/types';
import {
  ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
  associateServiceProfile,
  AssociateServiceProfilePayload,
} from './associate-service-profile';
import { POLL_NUMBER_ORDER_IDENTIFIER } from './poll-number-order';
import { PURCHASE_NUMBER_IDENTIFIER } from './purchase-number';
import { queueNextStepAsIfJobRan } from './queue-next-step-in-purchase-number-pipeline';

const setUpNumberRequest = async (
  client: PoolClient,
  options: { service: Service; service10DlcCampaign: string | null }
) => {
  const serviceProfileId = faker.random.uuid();
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
      profile_service_configuration_id: serviceProfileId,
    },
    triggers: true,
  });
  const request = await createPhoneNumberRequest(client, {
    area_code: '646',
    phone_number: options.service === Service.Telnyx ? '+16463893770' : null,
    sending_location: {
      center: '11238',
      profile: { type: 'existing', id: profile.id },
      triggers: true,
      type: 'create',
    },
    service_order_id:
      options.service === Service.Telnyx ? faker.random.uuid() : fakeSid(),
    triggers: true,
  });

  const updateQuery =
    options.service === Service.Telnyx
      ? `update sms.phone_number_requests set service_order_completed_at = now() where id = $1 returning *`
      : `update sms.phone_number_requests set phone_number = '+16463893770' where id = $1 returning *`;
  await client.query(updateQuery, [request.id]);

  await queueNextStepAsIfJobRan(
    client,
    profile.sending_account_id,
    profile.id,
    options.service === Service.Twilio
      ? PURCHASE_NUMBER_IDENTIFIER
      : POLL_NUMBER_ORDER_IDENTIFIER,
    request.id
  );

  const job = await findJob<AssociateServiceProfilePayload>(
    client,
    ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
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

  return { request, profile, serviceProfileId, job, getRequest };
};

describe('associate telnyx messaging profile', () => {
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
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(ASSOCIATE_SERVICE_PROFILE_IDENTIFIER);
    });
  });

  it('should create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Telnyx,
        service10DlcCampaign: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(ASSOCIATE_SERVICE_PROFILE_IDENTIFIER);
    });
  });

  it('associates telnyx profile successfully for non-10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { serviceProfileId, request, job, getRequest } =
        await setUpNumberRequest(client, {
          service: Service.Telnyx,
          service10DlcCampaign: null,
        });

      TelnyxNock.setMessagingProfile();

      const result = await associateServiceProfile(client, job.payload);
      expect(result).toEqual(serviceProfileId);

      expect(request.service_profile_associated_at).toBeNull();

      const finalRequest = await getRequest();
      expect(finalRequest.phone_number).not.toBeNull();
      expect(finalRequest.service_order_id).not.toBeNull();
      expect(finalRequest.tendlc_campaign_id).toBeNull();
      expect(finalRequest.service_order_completed_at).not.toBeNull();
      expect(finalRequest.service_profile_associated_at).not.toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).toBeNull();
      expect(finalRequest.fulfilled_at).not.toBeNull();
    });
  });

  it('associates telnyx profile successfully for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { profile, request, job, getRequest } = await setUpNumberRequest(
        client,
        {
          service: Service.Telnyx,
          service10DlcCampaign: faker.random.uuid(),
        }
      );

      TelnyxNock.setMessagingProfile();

      await associateServiceProfile(client, job.payload);

      expect(request.service_profile_associated_at).toBeNull();

      const finalRequest = await getRequest();
      expect(finalRequest.phone_number).not.toBeNull();
      expect(finalRequest.service_order_id).not.toBeNull();
      expect(finalRequest.tendlc_campaign_id).not.toBeNull();
      expect(finalRequest.service_order_completed_at).not.toBeNull();
      expect(finalRequest.service_profile_associated_at).not.toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).toBeNull();
      expect(finalRequest.fulfilled_at).toBeNull();
    });
  });
});

describe('associate twilio messaging service', () => {
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
      });

      expect(job).toBeUndefined();
    });
  });

  it('should NOT create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Twilio,
        service10DlcCampaign: faker.random.uuid(),
      });

      expect(job).toBeUndefined();
    });
  });
});
