import faker from 'faker';
import { Pool, PoolClient } from 'pg';

import {
  createPhoneNumberRequest,
  createProfile,
  createSendingAccount,
  createSendingLocation,
} from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { BandwidthNock, TelnyxNock, TwilioNock } from '../__tests__/nocks';
import { findJob, findJobs } from '../__tests__/numbers/utils';
import config from '../config';
import {
  PhoneNumberRequestRecord,
  ProfileRecord,
  Service,
  TenDlcCampaignRecord,
  TrafficChannel,
} from '../lib/types';
import {
  ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
  associateService10DLCCampaign,
  AssociateService10DLCCampaignPayload,
} from './associate-service-10dlc-campaign';
import { ASSOCIATE_SERVICE_PROFILE_IDENTIFIER } from './associate-service-profile';
import { POLL_NUMBER_ORDER_IDENTIFIER } from './poll-number-order';
import { PURCHASE_NUMBER_IDENTIFIER } from './purchase-number';
import { queueNextStepAsIfJobRan } from './queue-next-step-in-purchase-number-pipeline';

const setUpNumberRequest = async (
  client: PoolClient,
  options: { service: Service; service10DlcCampaign: string | null }
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
      profile_service_configuration_id: faker.random.uuid(),
    },
    triggers: true,
  });

  const isOrderBased = [Service.Bandwidth, Service.Telnyx].includes(
    options.service
  );

  const request = await createPhoneNumberRequest(client, {
    area_code: '646',
    phone_number: isOrderBased ? '+16463893770' : null,
    sending_location: {
      center: '11238',
      profile: { type: 'existing', id: profile.id },
      triggers: true,
      type: 'create',
    },
    service_order_id: faker.random.uuid(),
    triggers: true,
  });

  const phoneNumberRequestId = request.id;

  if (options.service === Service.Bandwidth) {
    await queueNextStepAsIfJobRan(
      client,
      profile.sending_account_id,
      profile.id,
      POLL_NUMBER_ORDER_IDENTIFIER,
      phoneNumberRequestId
    );
  } else if (options.service === Service.Telnyx) {
    await queueNextStepAsIfJobRan(
      client,
      profile.sending_account_id,
      profile.id,
      ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
      phoneNumberRequestId
    );
  } else if (options.service === Service.Twilio) {
    await client.query(
      `
        update sms.phone_number_requests
        set
          phone_number = '+16463893770',
          service_order_id = 'PNA2CCl5SbDGSocDqLH4mF8hL9lwG72ylm'
        where id = $1
      `,
      [request.id]
    );

    await queueNextStepAsIfJobRan(
      client,
      profile.sending_account_id,
      profile.id,
      PURCHASE_NUMBER_IDENTIFIER,
      phoneNumberRequestId
    );
  }

  const job = await findJob<AssociateService10DLCCampaignPayload>(
    client,
    ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
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

describe('associate telnyx 10DLC campaign', () => {
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
        service: Service.Telnyx,
        service10DlcCampaign: null,
      });

      expect(job).toBeUndefined();
    });
  });

  it('should create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Telnyx,
        service10DlcCampaign: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(
        ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER
      );
    });
  });

  it('associates telnyx 10DLC campaign successfully', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { request, job, getRequest } = await setUpNumberRequest(client, {
        service: Service.Telnyx,
        service10DlcCampaign: faker.random.uuid(),
      });

      await TelnyxNock.createPhoneNumberCampaign();

      await associateService10DLCCampaign(client, job.payload);

      const finalRequest = await getRequest();
      expect(request.service_10dlc_campaign_associated_at).toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).not.toBeNull();
      expect(finalRequest.fulfilled_at).not.toBeNull();
    });
  });
});

describe('associate twilio 10DLC campaign', () => {
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

  it('should create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Twilio,
        service10DlcCampaign: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(
        ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER
      );
    });
  });

  it('associates twilio profile successfully for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { request, job, getRequest } = await setUpNumberRequest(client, {
        service: Service.Twilio,
        service10DlcCampaign: faker.random.uuid(),
      });

      TwilioNock.getPhoneNumberId({});
      TwilioNock.setMessagingProfile({
        phoneNumber: request.phone_number!,
      });

      await associateService10DLCCampaign(client, job.payload);

      expect(request.service_profile_associated_at).toBeNull();
      expect(request.service_order_id).not.toBeNull();

      const finalRequest = await getRequest();
      expect(finalRequest.phone_number).not.toBeNull();
      expect(finalRequest.service_order_id).not.toBeNull();
      expect(finalRequest.tendlc_campaign_id).not.toBeNull();
      expect(finalRequest.service_order_completed_at).toBeNull();
      expect(finalRequest.service_profile_associated_at).toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).not.toBeNull();
      expect(finalRequest.fulfilled_at).not.toBeNull();
    });
  });
});

describe('associate bandwidth 10DLC campaign', () => {
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
        service: Service.Bandwidth,
        service10DlcCampaign: null,
      });

      expect(job).toBeUndefined();
    });
  });

  it('should create job for 10dlc purchase', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { job } = await setUpNumberRequest(client, {
        service: Service.Bandwidth,
        service10DlcCampaign: faker.random.uuid(),
      });

      expect(job).toBeDefined();
      expect(job.task_identifier).toEqual(
        ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER
      );
    });
  });

  it('associates bandwidth 10DLC campaign to TN successfully', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { request, job, getRequest } = await setUpNumberRequest(client, {
        service: Service.Bandwidth,
        service10DlcCampaign: faker.random.uuid(),
      });

      BandwidthNock.createTnOptionsOrder();

      await associateService10DLCCampaign(client, job.payload);

      const finalRequest = await getRequest();
      expect(request.service_10dlc_campaign_associated_at).toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).not.toBeNull();
      expect(finalRequest.fulfilled_at).not.toBeNull();
    });
  });
});

const setupFullPhoneNumberWithRequestGenerator = async (client: PoolClient) => {
  const sendingAccount = await createSendingAccount(client, {
    service: Service.Telnyx,
    triggers: true,
  });

  const profile = await createProfile(client, {
    client: { type: 'create' },
    sending_account: { type: 'existing', id: sendingAccount.id },
    profile_service_configuration: {
      type: 'create',
      profile_service_configuration_id: faker.random.uuid(),
    },
    triggers: true,
  });

  return async () => {
    const sendingLocation = await createSendingLocation(client, {
      center: '11238',
      profile: { type: 'existing', id: profile.id },
      triggers: true,
    });

    return async () => {
      const phoneNumberRequest = await createPhoneNumberRequest(client, {
        area_code: '11238',
        sending_location: { type: 'existing', id: sendingLocation.id },
        triggers: true,
      });

      await client.query(
        `
    update sms.phone_number_requests
    set
      service_order_id = $1,
      phone_number = $2,
      fulfilled_at = now()
    where id = $3
  `,
        [
          faker.random.uuid(),
          faker.phone.phoneNumber('+1##########'),
          phoneNumberRequest.id,
        ]
      );

      return { profileId: profile.id };
    };
  };
};

describe('attach_10dlc_campaign_to_profile sql function', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('should update throughput limits', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const doCreateSendingLocation =
        await setupFullPhoneNumberWithRequestGenerator(client);
      const createPhoneNumber = await doCreateSendingLocation();
      const { profileId } = await createPhoneNumber();

      const telnyx10DlcCampaignIdentifier = faker.random.uuid();
      await client.query('select attach_10dlc_campaign_to_profile($1, $2)', [
        profileId,
        telnyx10DlcCampaignIdentifier,
      ]);

      const tenDlcCampaignId = await client
        .query<TenDlcCampaignRecord>(
          `select * from sms.tendlc_campaigns where registrar_campaign_id = $1`,
          [telnyx10DlcCampaignIdentifier]
        )
        .then(({ rows }) => rows[0].id);

      const {
        rows: [profile],
      } = await client.query<
        Pick<
          ProfileRecord,
          'tendlc_campaign_id' | 'throughput_limit' | 'daily_contact_limit'
        >
      >('select * from sms.profiles where id = $1', [profileId]);
      expect(profile.tendlc_campaign_id).toEqual(tenDlcCampaignId);
      expect(profile.throughput_limit).toEqual(4500);
      expect(profile.daily_contact_limit).toEqual(3 * 1000000);
    });
  });

  test('should cordon all except 1 per sending location', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const doCreateSendingLocation =
        await setupFullPhoneNumberWithRequestGenerator(client);

      const createPhoneNumberInLocation1 = await doCreateSendingLocation();
      const { profileId } = await createPhoneNumberInLocation1();
      await createPhoneNumberInLocation1();

      const createPhoneNumberInLocation2 = await doCreateSendingLocation();
      await createPhoneNumberInLocation2();
      await createPhoneNumberInLocation2();

      const telnyx10DlcCampaignIdentifier = faker.random.uuid();
      await client.query('select attach_10dlc_campaign_to_profile($1, $2)', [
        profileId,
        telnyx10DlcCampaignIdentifier,
      ]);

      const { rows } = await client.query<{
        c: number;
        sending_location_id: string;
        is_cordoned: boolean;
      }>(
        'select count(*) as c, sending_location_id, cordoned_at is null as is_cordoned from sms.all_phone_numbers group by 2, 3'
      );

      for (const row of rows) {
        expect(row.c).toEqual('1');
      }
    });
  });

  test('should create n associate jobs', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const doCreateSendingLocation =
        await setupFullPhoneNumberWithRequestGenerator(client);

      const createPhoneNumberInLocation1 = await doCreateSendingLocation();
      const { profileId } = await createPhoneNumberInLocation1();
      await createPhoneNumberInLocation1();

      const createPhoneNumberInLocation2 = await doCreateSendingLocation();
      await createPhoneNumberInLocation2();
      await createPhoneNumberInLocation2();

      const telnyx10DlcCampaignIdentifier = faker.random.uuid();
      await client.query('select attach_10dlc_campaign_to_profile($1, $2)', [
        profileId,
        telnyx10DlcCampaignIdentifier,
      ]);

      const jobs = await findJobs(
        client,
        ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
        'profile_id',
        profileId
      );
      expect(jobs.length).toEqual(2);
    });
  });
});
