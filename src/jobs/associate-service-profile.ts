import type { PoolClient } from 'pg';
import { z } from 'zod';

import { InvalidProfileConfigurationError } from '../lib/errors';
import { getTelcoClient } from '../lib/services';
import { profileConfigCache, sendingAccountCache } from '../models/cache';
import { wrapWithQueueNextStepInPurchaseNumberPipeline } from './queue-next-step-in-purchase-number-pipeline';

export const ASSOCIATE_SERVICE_PROFILE_IDENTIFIER = 'associate-service-profile';

// tslint:disable-next-line: variable-name
export const AssociateServiceProfilePayloadSchema = z
  .object({
    id: z.string().uuid(),
    sending_account_id: z.string().uuid(),
    profile_id: z.string().uuid(),
    phone_number: z.string(),
  })
  .required();

export type AssociateServiceProfilePayload = z.infer<
  typeof AssociateServiceProfilePayloadSchema
>;

export const associateServiceProfile =
  wrapWithQueueNextStepInPurchaseNumberPipeline(
    ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
    async (client: PoolClient, rawPayload: unknown) => {
      const payload = AssociateServiceProfilePayloadSchema.parse(rawPayload);
      const { id: phoneNumberRequestId, sending_account_id } = payload;
      const sendingAccount = await sendingAccountCache.getSendingAccount(
        client,
        sending_account_id
      );
      const { service_profile_id } = await profileConfigCache.getProfileConfig(
        client,
        payload.profile_id
      );

      if (!service_profile_id) {
        throw new InvalidProfileConfigurationError(
          sendingAccount.service,
          sendingAccount.sending_account_id,
          'service_profile_id was null'
        );
      }

      const result = await getTelcoClient(
        sendingAccount
      ).associateServiceProfile({
        phoneNumber: payload.phone_number,
        serviceProfileId: service_profile_id,
      });

      await client.query(
        `
          update sms.phone_number_requests
          set service_profile_associated_at = now()
          where id = $1
        `,
        [phoneNumberRequestId]
      );

      return result;
    }
  );
