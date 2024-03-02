import isNil from 'lodash/isNil';
import type { PoolClient } from 'pg';
import { z } from 'zod';

import {
  NoAvailableNumbersError,
  NoFallbackAreaCodeError,
} from '../lib/errors';
import { findOneSuitableAreaCode } from '../lib/geo';
import { getTelcoClient } from '../lib/services';
import { PurchaseNumberCallbackPayload } from '../lib/services/service';
import { SendingLocationPurchasingStrategy } from '../lib/types';
import { doesLivePhoneNumberExist } from '../lib/utils';
import { logger } from '../logger';
import { profileConfigCache, sendingAccountCache } from '../models/cache';
import { wrapWithQueueNextStepInPurchaseNumberPipeline } from './queue-next-step-in-purchase-number-pipeline';
import { PurchaseNumberPayloadSchema } from './schema-validation';

export const PURCHASE_NUMBER_IDENTIFIER = 'purchase-number';

// tslint:disable-next-line variable-name
const TrimmedPurchaseNumberPayloadSchema = PurchaseNumberPayloadSchema.pick({
  id: true,
  area_code: true,
  profile_id: true,
  sending_account_id: true,
  service: true,
  sending_location_id: true,
});

type TrimmedPurchaseNumberPayload = z.infer<
  typeof TrimmedPurchaseNumberPayloadSchema
>;

const getFallbackAreaCode = async (
  client: PoolClient,
  {
    area_code,
    service,
    sending_account_id,
    sending_location_id,
  }: TrimmedPurchaseNumberPayload
) => {
  const {
    rows: [{ center, purchasing_strategy: strategy }],
  } = await client.query(
    'select center, purchasing_strategy from sms.sending_locations where id = $1',
    [sending_location_id]
  );

  if (strategy === SendingLocationPurchasingStrategy.ExactAreaCodes) {
    throw new Error('Can not find fallback for exact-area-codes');
  }

  const fallbackAreaCode = await findOneSuitableAreaCode(client, {
    center,
    sending_account_id,
  });

  if (isNil(fallbackAreaCode)) {
    throw new NoFallbackAreaCodeError(service, area_code);
  }

  return fallbackAreaCode;
};

// To test this, we need a sending location to have specific area codes where there are none,
// and to have available numbers nearby
// we should test that the number that gets purchased is from one of the nearby ones
export const purchaseNumber = wrapWithQueueNextStepInPurchaseNumberPipeline(
  PURCHASE_NUMBER_IDENTIFIER,
  async (client: PoolClient, rawPayload) => {
    const payload = TrimmedPurchaseNumberPayloadSchema.parse(rawPayload);
    const {
      area_code: initialAreaCode,
      profile_id,
      sending_account_id,
    } = payload;

    const claimNumber = async (phoneNumber: string) => {
      logger.debug('purchase-number: attempting claim number', { phoneNumber });
      await client.query('savepoint claim_number;');
      try {
        await client.query(
          `
          update sms.phone_number_requests
          set phone_number = $1
          where id = $2;
        `,
          [phoneNumber, payload.id]
        );
        await client.query('release savepoint claim_number;');
      } catch (ex) {
        await client.query('rollback to savepoint claim_number;');
        logger.error('purchase-number error (claiming number): ', ex);
        // still need to get the original error
        throw ex;
      }
    };

    const saveResult = async (result: PurchaseNumberCallbackPayload) => {
      logger.debug('purchase-number: attempting save result', result);
      await client
        .query(
          `
          update sms.phone_number_requests
          set
            service_order_id = $1,
            phone_number = $2
          where id = $3;
        `,
          [result.orderId ?? null, result.phoneNumber, payload.id]
        )
        .catch((ex) => {
          logger.error('purchase-number error (saving result): ', ex);
          throw ex;
        });
    };

    const sendingAccount = await sendingAccountCache.getSendingAccount(
      client,
      sending_account_id
    );
    const telcoClient = getTelcoClient(sendingAccount);

    const attemptPurchaseInAreaCode = async (areaCode: string) => {
      const { service_profile_id } = await profileConfigCache.getProfileConfig(
        client,
        profile_id
      );
      const attemptPayload = {
        ...payload,
        area_code: areaCode,
        service_profile_id,
        claimNumber,
        saveResult,
        voice_callback_url: null,
        tendlc_campaign_id: null,
        doesLivePhoneNumberExist: (phoneNumber: string) =>
          doesLivePhoneNumberExist(client, phoneNumber),
      };
      await telcoClient.purchaseNumber(attemptPayload);
    };

    await attemptPurchaseInAreaCode(initialAreaCode).catch(async (err) => {
      if (err instanceof NoAvailableNumbersError) {
        logger.warn(`Got 0 matching numbers from ${err.service}`, {
          areaCode: initialAreaCode,
        });
        const fallbackAreaCode = await getFallbackAreaCode(client, payload);
        await attemptPurchaseInAreaCode(fallbackAreaCode);
        return;
      }
      throw err;
    });
  }
);
