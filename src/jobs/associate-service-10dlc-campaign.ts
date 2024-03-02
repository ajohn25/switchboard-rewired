import { PoolClient } from 'pg';
import { z } from 'zod';

import { getTelcoClient } from '../lib/services';
import { TenDlcCampaignRecord } from '../lib/types';
import { sendingAccountCache } from '../models/cache';
import { wrapWithQueueNextStepInPurchaseNumberPipeline } from './queue-next-step-in-purchase-number-pipeline';

export const ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER =
  'associate-service-10dlc-campaign';

// tslint:disable-next-line: variable-name
export const AssociateService10DLCCampaignPayloadSchema = z
  .object({
    id: z.string().uuid(),
    phone_number: z.string(),
    tendlc_campaign_id: z.string().uuid(),
    sending_account_id: z.string().uuid(),
  })
  .required();

export type AssociateService10DLCCampaignPayload = z.infer<
  typeof AssociateService10DLCCampaignPayloadSchema
>;

export const associateService10DLCCampaign =
  wrapWithQueueNextStepInPurchaseNumberPipeline(
    ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
    async (client: PoolClient, rawPayload: unknown) => {
      const payload =
        AssociateService10DLCCampaignPayloadSchema.parse(rawPayload);
      const {
        id: phoneNumberRequestId,
        phone_number: phoneNumber,
        tendlc_campaign_id: campaignId,
      } = payload;

      const tenDlcCampaign = await client
        .query<TenDlcCampaignRecord>(
          `select registrar_account_id, registrar_campaign_id from sms.tendlc_campaigns where id = $1`,
          [campaignId]
        )
        .then(({ rows }) => rows[0]);

      if (tenDlcCampaign.registrar_account_id !== payload.sending_account_id) {
        throw new Error(
          '10DLC campaign and profile have different sending accounts!'
        );
      }

      if (tenDlcCampaign.registrar_campaign_id === null) {
        throw new Error(
          `10DLC campaign ${tenDlcCampaign} has null registrar ID!`
        );
      }

      const sendingAccount = await sendingAccountCache.getSendingAccount(
        client,
        payload.sending_account_id
      );

      await getTelcoClient(sendingAccount).associate10dlcCampaignTn({
        phoneNumber,
        campaignId: tenDlcCampaign.registrar_campaign_id,
      });

      await client.query(
        `
          update sms.phone_number_requests
          set service_10dlc_campaign_associated_at = now()
          where id = $1
        `,
        [phoneNumberRequestId]
      );
    }
  );
