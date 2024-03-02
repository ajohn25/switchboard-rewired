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
import {
  countJobs,
  findJob,
  findJobWithArrayIncludes,
} from '../__tests__/numbers/utils';
import config from '../config';
import {
  PhoneNumberRequestRecord,
  ProfileRecord,
  SendingLocationPurchasingStrategy,
  Service,
  TrafficChannel,
} from '../lib/types';
import {
  ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
  associateService10DLCCampaign,
  AssociateService10DLCCampaignPayload,
} from './associate-service-10dlc-campaign';
import {
  ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
  associateServiceProfile,
  AssociateServiceProfilePayload,
} from './associate-service-profile';
import { ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER } from './estimate-area-code-capacity';
import { FIND_SUITABLE_AREA_CODES_IDENTIFIER } from './find-suitable-area-codes';
import {
  POLL_NUMBER_ORDER_IDENTIFIER,
  pollNumberOrder,
  PollNumberOrderPayload,
} from './poll-number-order';
import { PURCHASE_NUMBER_IDENTIFIER, purchaseNumber } from './purchase-number';
import { PurchaseNumberPayload } from './schema-validation';

interface PurchaseNumberSetup {
  getRequest: () => Promise<PhoneNumberRequestRecord>;
  phoneNumberRequest: PhoneNumberRequestRecord;
  profile: ProfileRecord;
  serviceProfileId: string;
}

interface SetupPurchaseNumberOptions {
  service: Service;
  areaCode: string;
  capacityCount?: number;
  purchasingStrategy?: SendingLocationPurchasingStrategy;
  serviceProfileId?: string;
  service10DlcCampaign?: string;
  center?: string;
}

export const setupPurchaseNumber = async (
  client: PoolClient,
  options: SetupPurchaseNumberOptions
): Promise<PurchaseNumberSetup> => {
  const {
    service,
    areaCode,
    capacityCount,
    purchasingStrategy,
    service10DlcCampaign,
    center = '11205',
  } = options;
  const sendingAccount = await createSendingAccount(client, {
    service,
    triggers: true,
  });
  const serviceProfileId =
    service === Service.Twilio
      ? `MS${faker.random.alphaNumeric(30)}`
      : faker.random.uuid();
  const profile = await createProfile(client, {
    client: { type: 'create' },
    sending_account: { type: 'existing', id: sendingAccount.id },
    ...(service10DlcCampaign
      ? {
          channel: TrafficChannel.TenDlc,
          tenDlcCampaign: { registrarCampaignId: service10DlcCampaign },
        }
      : { channel: TrafficChannel.GreyRoute }),
    profile_service_configuration: {
      type: 'create',
      profile_service_configuration_id: serviceProfileId,
    },
    triggers: true,
  });
  const sendingLocation = await createSendingLocation(client, {
    center,
    profile: { type: 'existing', id: profile.id },
    purchasing_strategy: purchasingStrategy,
    triggers: true,
  });
  const phoneNumberRequest = await createPhoneNumberRequest(client, {
    area_code: areaCode,
    sending_location: { type: 'existing', id: sendingLocation.id },
    triggers: true,
  });

  if (capacityCount !== undefined) {
    await client.query(
      'insert into sms.area_code_capacities (area_code, sending_account_id, capacity) values ($1, $2, $3)',
      [areaCode, sendingAccount.id, capacityCount ?? 10]
    );
  }

  const getRequest = async () =>
    client
      .query<PhoneNumberRequestRecord>(
        `select * from sms.phone_number_requests where id = $1`,
        [phoneNumberRequest.id]
      )
      .then(({ rows: [request] }) => request);

  return {
    getRequest,
    phoneNumberRequest,
    profile,
    serviceProfileId,
  };
};

describe('purchase number', () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  test('should purchase a non-10DLC number from Twilio', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const areaCode = faker.phone.phoneNumber('###');
      const { phoneNumberRequest, getRequest } = await setupPurchaseNumber(
        client,
        {
          areaCode,
          service: Service.Twilio,
        }
      );

      TwilioNock.purchaseNumber({ code: 200 });

      const queuedJob = await findJob(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      await purchaseNumber(client, queuedJob.payload as PurchaseNumberPayload);

      const finalRequest = await getRequest();

      const { phone_number, service_order_id, fulfilled_at } = finalRequest;
      expect(phone_number).toMatch(new RegExp(`\\+1${areaCode}[\\d]{7}`));
      expect(service_order_id).not.toBeNull();
      expect(fulfilled_at).not.toBeNull();
    });
  });

  test('should purchase a 10DLC number from Twilio', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const areaCode = faker.phone.phoneNumber('###');
      const messagingServiceSid = `MS${faker.random.alphaNumeric(32)}`;
      const { phoneNumberRequest, getRequest } = await setupPurchaseNumber(
        client,
        {
          areaCode,
          service: Service.Twilio,
          service10DlcCampaign: messagingServiceSid,
        }
      );

      TwilioNock.getPhoneNumberId({});
      TwilioNock.purchaseNumber({ code: 200 });

      const queuedJob = await findJob<PurchaseNumberPayload>(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      await purchaseNumber(client, queuedJob.payload);

      const associateProfileJob =
        await findJob<AssociateService10DLCCampaignPayload>(
          client,
          ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

      TwilioNock.setMessagingProfile();

      await associateService10DLCCampaign(client, associateProfileJob.payload);

      const finalRequest = await getRequest();

      const { phone_number, service_order_id, fulfilled_at } = finalRequest;
      expect(phone_number).toMatch(new RegExp(`\\+1${areaCode}[\\d]{7}`));
      expect(service_order_id).not.toBeNull();
      expect(fulfilled_at).not.toBeNull();
    });
  });

  test('should purchase a non-10DLC number from Telnyx', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const areaCode = faker.phone.phoneNumber('###');
      let fakePhoneNumber = '';

      const { phoneNumberRequest, serviceProfileId, getRequest } =
        await setupPurchaseNumber(client, {
          areaCode,
          service: Service.Telnyx,
        });

      const queuedJob = await findJob<PurchaseNumberPayload>(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getAvailableNumbers({
        callback: ([phoneNumber]) => {
          fakePhoneNumber = phoneNumber;
        },
        targetCapacity: 1,
        times: 1,
        using: 'times',
      });
      TelnyxNock.createNumberOrder({
        serviceProfileId,
      });

      await purchaseNumber(client, queuedJob.payload);

      const queuedPollingJob = await findJob<PollNumberOrderPayload>(
        client,
        POLL_NUMBER_ORDER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getNumberOrder({
        phoneNumbers: [fakePhoneNumber],
        serviceProfileId,
        status: 'success',
      });

      await pollNumberOrder(client, queuedPollingJob.payload);

      const associateProfileJob = await findJob<AssociateServiceProfilePayload>(
        client,
        ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.setMessagingProfile();

      const result = await associateServiceProfile(
        client,
        associateProfileJob.payload
      );
      expect(result).toEqual(serviceProfileId);

      const finalRequest = await getRequest();

      const { phone_number, fulfilled_at } = finalRequest;
      expect(phone_number).toMatch(new RegExp(`\\+1${areaCode}[\\d]{7}`));
      expect(fulfilled_at).not.toBeNull();
    });
  });

  test('should purchase a 10DLC number from Telnyx', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const areaCode = faker.phone.phoneNumber('###');
      let fakePhoneNumber = '';

      const { phoneNumberRequest, serviceProfileId, getRequest } =
        await setupPurchaseNumber(client, {
          areaCode,
          service: Service.Telnyx,
          service10DlcCampaign: faker.random.uuid(),
        });

      const queuedJob = await findJob<PurchaseNumberPayload>(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getAvailableNumbers({
        callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
        targetCapacity: 1,
        times: 1,
        using: 'times',
      });
      TelnyxNock.createNumberOrder({
        serviceProfileId,
      });

      await purchaseNumber(client, queuedJob.payload);

      const queuedPollingJob = await findJob<PollNumberOrderPayload>(
        client,
        POLL_NUMBER_ORDER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getNumberOrder({
        phoneNumbers: [fakePhoneNumber],
        serviceProfileId,
        status: 'success',
      });

      await pollNumberOrder(client, queuedPollingJob.payload);

      const associateProfileJob = await findJob<AssociateServiceProfilePayload>(
        client,
        ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.setMessagingProfile();

      const result = await associateServiceProfile(
        client,
        associateProfileJob.payload
      );
      expect(result).toEqual(serviceProfileId);

      const associate10DlcJob =
        await findJob<AssociateService10DLCCampaignPayload>(
          client,
          ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

      TelnyxNock.createPhoneNumberCampaign();

      await associateService10DLCCampaign(client, associate10DlcJob.payload);

      const finalRequest = await getRequest();

      expect(finalRequest.phone_number).toMatch(
        new RegExp(`\\+1${areaCode}[\\d]{7}`)
      );
      expect(finalRequest.service_order_id).not.toBeNull();
      expect(finalRequest.service_order_completed_at).not.toBeNull();
      expect(finalRequest.service_profile_associated_at).not.toBeNull();
      expect(finalRequest.service_10dlc_campaign_associated_at).not.toBeNull();
      expect(finalRequest.fulfilled_at).not.toBeNull();
    });
  });

  test('should skip purchasing a duplicate number from Telnyx', async () => {
    const areaCode = faker.phone.phoneNumber('###');
    const duplicatePhoneNumber = `+1${areaCode}${faker.phone.phoneNumber(
      '#######'
    )}`;
    const nextPhoneNumber = `+1${areaCode}${faker.phone.phoneNumber(
      '#######'
    )}`;

    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { phoneNumberRequest, profile, serviceProfileId, getRequest } =
        await setupPurchaseNumber(client, {
          areaCode,
          service: Service.Telnyx,
        });

      const duplicateSendingLocation = await createSendingLocation(client, {
        center: '11205',
        profile: { type: 'existing', id: profile.id },
        triggers: true,
      });
      await client.query(
        `insert into sms.all_phone_numbers (phone_number, sending_location_id) values ($1, $2)`,
        [duplicatePhoneNumber, duplicateSendingLocation.id]
      );

      const queuedJob = await findJob(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getAvailableNumbers({
        phoneNumbers: [duplicatePhoneNumber, nextPhoneNumber],
        using: 'phoneNumbers',
      });
      TelnyxNock.createNumberOrder({
        serviceProfileId,
      });

      const jobPayload = queuedJob.payload as PurchaseNumberPayload;
      await purchaseNumber(client, jobPayload);

      const { phone_number: purchasedNumber } = await getRequest();

      expect(purchasedNumber).toEqual(nextPhoneNumber);
    });
  });

  test('should purchase a non-10DLC number from Bandwidth', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const areaCode = faker.phone.phoneNumber('###');
      let fakePhoneNumber = '';

      const { phoneNumberRequest, profile, getRequest } =
        await setupPurchaseNumber(client, {
          areaCode,
          service: Service.Bandwidth,
        });

      const queuedJob = await findJob<PurchaseNumberPayload>(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      BandwidthNock.getAvailableNumbers({
        callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
        targetCapacity: 1,
        times: 1,
        using: 'times',
      });
      BandwidthNock.createNumberOrder();

      await purchaseNumber(client, queuedJob.payload);

      const queuedPollingJob = await findJob<PollNumberOrderPayload>(
        client,
        POLL_NUMBER_ORDER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      BandwidthNock.getNumberOrder({
        phoneNumbers: [fakePhoneNumber],
        status: 'COMPLETE',
      });

      await pollNumberOrder(client, queuedPollingJob.payload);

      const finalRequest = await getRequest();

      const { phone_number, fulfilled_at } = finalRequest;
      expect(phone_number).toMatch(new RegExp(`\\+1${areaCode}[\\d]{7}`));
      expect(fulfilled_at).not.toBeNull();
    });
  });

  test('should decerement capacity after purchase number', async () => {
    const areaCode = faker.phone.phoneNumber('###');
    let fakePhoneNumber: string;
    const newCapacity = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { phoneNumberRequest, serviceProfileId } =
          await setupPurchaseNumber(client, {
            areaCode,
            capacityCount: 10,
            service: Service.Telnyx,
          });

        const queuedJob = await findJob(
          client,
          PURCHASE_NUMBER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getAvailableNumbers({
          callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
          targetCapacity: 1,
          times: 1,
          using: 'times',
        });
        TelnyxNock.createNumberOrder({
          serviceProfileId,
        });

        const payload = queuedJob.payload as PurchaseNumberPayload;
        await purchaseNumber(client, payload);

        const queuedPollingJob = await findJob(
          client,
          POLL_NUMBER_ORDER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getNumberOrder({
          phoneNumbers: [fakePhoneNumber],
          serviceProfileId,
          status: 'success',
        });
        TelnyxNock.setMessagingProfile();

        await pollNumberOrder(
          client,
          queuedPollingJob.payload as PollNumberOrderPayload
        );

        const associateProfileJob =
          await findJob<AssociateServiceProfilePayload>(
            client,
            ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
            'id',
            phoneNumberRequest.id
          );

        TelnyxNock.setMessagingProfile();

        const result = await associateServiceProfile(
          client,
          associateProfileJob.payload
        );
        expect(result).toEqual(serviceProfileId);

        const {
          rows: [{ capacity }],
        } = await client.query(
          'select capacity from sms.area_code_capacities where area_code = $1 and sending_account_id = $2',
          [payload.area_code, payload.sending_account_id]
        );

        return capacity;
      }
    );

    expect(newCapacity).toBe(9);
  });

  test('should queue a capacity refresh if mod 5', async () => {
    const areaCode = faker.phone.phoneNumber('###');
    let fakePhoneNumber: string;
    const job = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { phoneNumberRequest, serviceProfileId } =
          await setupPurchaseNumber(client, {
            areaCode,
            capacityCount: 11,
            purchasingStrategy:
              SendingLocationPurchasingStrategy.ExactAreaCodes,
            service: Service.Telnyx,
          });

        const queuedJob = await findJob(
          client,
          PURCHASE_NUMBER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getAvailableNumbers({
          callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
          targetCapacity: 1,
          times: 1,
          using: 'times',
        });
        TelnyxNock.createNumberOrder({
          serviceProfileId,
        });

        const payload = queuedJob.payload as PurchaseNumberPayload;
        await purchaseNumber(client, payload);

        const queuedPollingJob = await findJob(
          client,
          POLL_NUMBER_ORDER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getNumberOrder({
          phoneNumbers: [fakePhoneNumber],
          serviceProfileId,
          status: 'success',
        });
        TelnyxNock.setMessagingProfile();

        await pollNumberOrder(
          client,
          queuedPollingJob.payload as PollNumberOrderPayload
        );

        const associateProfileJob =
          await findJob<AssociateServiceProfilePayload>(
            client,
            ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
            'id',
            phoneNumberRequest.id
          );

        TelnyxNock.setMessagingProfile();

        const result = await associateServiceProfile(
          client,
          associateProfileJob.payload
        );
        expect(result).toEqual(serviceProfileId);

        const foundJob = await findJobWithArrayIncludes(
          client,
          ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
          'area_codes',
          payload.area_code
        );

        return foundJob;
      }
    );

    expect(job).not.toBeNull();
    expect(job.payload).toHaveProperty('area_codes');
    expect(job.payload.area_codes.includes(areaCode)).toBeTruthy();
  });

  test('should queue a find-suitable-area-codes refresh if mod 5', async () => {
    const areaCode = faker.phone.phoneNumber('###');
    let fakePhoneNumber: string;
    const jobCount = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { phoneNumberRequest, serviceProfileId } =
          await setupPurchaseNumber(client, {
            areaCode,
            capacityCount: 11,
            purchasingStrategy:
              SendingLocationPurchasingStrategy.SameStateByDistance,
            service: Service.Telnyx,
          });

        const queuedJob = await findJob(
          client,
          PURCHASE_NUMBER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getAvailableNumbers({
          callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
          targetCapacity: 1,
          times: 1,
          using: 'times',
        });
        TelnyxNock.createNumberOrder({
          serviceProfileId,
        });

        const payload = queuedJob.payload as PurchaseNumberPayload;
        await purchaseNumber(client, payload);

        const queuedPollingJob = await findJob(
          client,
          POLL_NUMBER_ORDER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getNumberOrder({
          phoneNumbers: [fakePhoneNumber],
          serviceProfileId,
          status: 'success',
        });
        TelnyxNock.setMessagingProfile();

        await pollNumberOrder(
          client,
          queuedPollingJob.payload as PollNumberOrderPayload
        );

        const associateProfileJob =
          await findJob<AssociateServiceProfilePayload>(
            client,
            ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
            'id',
            phoneNumberRequest.id
          );

        TelnyxNock.setMessagingProfile();

        const result = await associateServiceProfile(
          client,
          associateProfileJob.payload
        );
        expect(result).toEqual(serviceProfileId);

        const count = await countJobs(
          client,
          FIND_SUITABLE_AREA_CODES_IDENTIFIER,
          'id',
          payload.sending_location_id
        );

        return count;
      }
    );

    // 2 means success - the first job is a by product of setupNumber
    expect(jobCount).toBe(2);
  });

  test("should fall back to polling the number's status", async () => {
    const areaCode = faker.phone.phoneNumber('###');
    let fakePhoneNumber: string;
    const jobCount = await withPgMiddlewares(
      pool,
      [autoRollbackMiddleware],
      async (client) => {
        const { phoneNumberRequest, serviceProfileId, getRequest } =
          await setupPurchaseNumber(client, {
            areaCode,
            capacityCount: 11,
            purchasingStrategy:
              SendingLocationPurchasingStrategy.SameStateByDistance,
            service: Service.Telnyx,
          });

        const queuedJob = await findJob(
          client,
          PURCHASE_NUMBER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getAvailableNumbers({
          callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
          targetCapacity: 1,
          times: 1,
          using: 'times',
        });
        TelnyxNock.createNumberOrder({
          serviceProfileId,
        });

        const payload = queuedJob.payload as PurchaseNumberPayload;
        await purchaseNumber(client, payload);

        const queuedPollingJob = await findJob(
          client,
          POLL_NUMBER_ORDER_IDENTIFIER,
          'id',
          phoneNumberRequest.id
        );

        TelnyxNock.getNumberOrder({
          phoneNumbers: [fakePhoneNumber],
          serviceProfileId,
          status: 'pending',
        });
        TelnyxNock.getPhoneNumbers([
          {
            phoneNumber: fakePhoneNumber,
            serviceProfileId,
            status: 'active',
          },
        ]);
        TelnyxNock.setMessagingProfile();

        await pollNumberOrder(
          client,
          queuedPollingJob.payload as PollNumberOrderPayload
        );

        const associateProfileJob =
          await findJob<AssociateServiceProfilePayload>(
            client,
            ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
            'id',
            phoneNumberRequest.id
          );

        TelnyxNock.setMessagingProfile();

        const result = await associateServiceProfile(
          client,
          associateProfileJob.payload
        );
        expect(result).toEqual(serviceProfileId);

        const count = await countJobs(
          client,
          FIND_SUITABLE_AREA_CODES_IDENTIFIER,
          'id',
          payload.sending_location_id
        );

        return count;
      }
    );

    // 2 means success - the first job is a by product of setupNumber
    expect(jobCount).toBe(2);
  });

  test('should error when fallback number status check also fails', async () => {
    const areaCode = faker.phone.phoneNumber('###');
    let fakePhoneNumber: string;
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { phoneNumberRequest, serviceProfileId } =
        await setupPurchaseNumber(client, {
          areaCode,
          capacityCount: 11,
          purchasingStrategy:
            SendingLocationPurchasingStrategy.SameStateByDistance,
          service: Service.Telnyx,
        });

      const queuedJob = await findJob(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getAvailableNumbers({
        callback: ([phoneNumber]) => (fakePhoneNumber = phoneNumber),
        targetCapacity: 1,
        times: 1,
        using: 'times',
      });
      TelnyxNock.createNumberOrder({
        serviceProfileId,
      });

      const payload = queuedJob.payload as PurchaseNumberPayload;
      await purchaseNumber(client, payload);

      const queuedPollingJob = await findJob(
        client,
        POLL_NUMBER_ORDER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TelnyxNock.getNumberOrder({
        phoneNumbers: [fakePhoneNumber],
        serviceProfileId,
        status: 'pending',
      });
      TelnyxNock.getPhoneNumbers([
        {
          phoneNumber: fakePhoneNumber,
          serviceProfileId,
          status: 'purchase_pending',
        },
      ]);

      await pollNumberOrder(
        client,
        queuedPollingJob.payload as PollNumberOrderPayload
      ).catch((err) =>
        expect(err.message).toMatch(
          /^telnyx number \+1[\d]{10,10} was not successful. Got status purchase_pending$/
        )
      );
    });
  });

  test('should buy a number from a different area code on error', async () => {
    const firstAttempt = '212';
    const fallbackAreaCode = '646';

    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const { phoneNumberRequest, getRequest } = await setupPurchaseNumber(
        client,
        {
          areaCode: firstAttempt,
          capacityCount: 11,
          purchasingStrategy:
            SendingLocationPurchasingStrategy.SameStateByDistance,
          service: Service.Twilio,
        }
      );

      const queuedJob = await findJob(
        client,
        PURCHASE_NUMBER_IDENTIFIER,
        'id',
        phoneNumberRequest.id
      );

      TwilioNock.getNumberAvailability(10, 10, fallbackAreaCode);
      TwilioNock.purchaseNumber({ code: 400 });
      TwilioNock.purchaseNumber({ code: 200 });

      await purchaseNumber(client, queuedJob.payload as PurchaseNumberPayload);

      const { phone_number: finalPurchase } = await getRequest();
      expect(finalPurchase).not.toBeUndefined();
      const finalAreaCode = finalPurchase!.slice(2, 5);
      expect(firstAttempt).not.toBe(finalAreaCode);
      expect(finalAreaCode).toBe(fallbackAreaCode);
    });
  });
});
