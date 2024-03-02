import { z } from 'zod';

import { getTelcoClient } from '../lib/services';
import { TenDlcCampaignRecord, WrappableTask } from '../lib/types';
import { sendingAccountCache } from '../models/cache';

export const GET_MNO_METADATA_IDENTIFIER = 'get-mno-metadata';

// tslint:disable-next-line variable-name
export const AssociateServiceProfilePayloadSchema = z.object({
  id: z.string().uuid(),
});

export type AssociateServiceProfilePayload = z.infer<
  typeof AssociateServiceProfilePayloadSchema
>;

export const getMnoMetadata: WrappableTask = async (client, rawPayload) => {
  const payload = AssociateServiceProfilePayloadSchema.parse(rawPayload);

  const {
    rows: [tenDlcCampaign],
  } = await client.query<TenDlcCampaignRecord>(
    `select * from sms.tendlc_campaigns where id = $1`,
    [payload.id]
  );

  const {
    tcr_account_id,
    tcr_campaign_id,
    registrar_account_id,
    registrar_campaign_id,
  } = tenDlcCampaign;

  const campaignId = tcr_campaign_id ?? registrar_campaign_id;
  const sendingAccountId = tcr_account_id ?? registrar_account_id;

  if (campaignId === null) {
    throw new Error(
      `10DLC campaign ${tenDlcCampaign.id} record had null campaign IDs`
    );
  }
  if (sendingAccountId === null) {
    throw new Error(
      `10DLC campaign ${tenDlcCampaign.id} record had null sending account IDs`
    );
  }

  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sendingAccountId
  );

  const mnoMetaData = await getTelcoClient(sendingAccount).getMnoMetadata({
    campaignId,
  });

  const mnoPayloads = Object.entries<any>(mnoMetaData).map(
    ([mnoId, metadata]) => {
      const {
        mno,
        qualify,
        tpm,
        brandTier,
        msgClass,
        mnoReview,
        mnoSupport,
        minMsgSamples,
        reqSubscriberHelp,
        reqSubscriberOptin,
        reqSubscriberOptout,
        noEmbeddedPhone,
        noEmbeddedLink,
        ...extra
      } = metadata;

      return {
        mno_id: mnoId,
        mno,
        qualify,
        tpm,
        brand_tier: brandTier,
        msg_class: msgClass,
        mno_review: mnoReview,
        mno_support: mnoSupport,
        min_msg_samples: minMsgSamples,
        req_subscriber_help: reqSubscriberHelp,
        req_subscriber_optin: reqSubscriberOptin,
        req_subscriber_optout: reqSubscriberOptout,
        no_embedded_phone: noEmbeddedPhone,
        no_embedded_link: noEmbeddedLink,
        extra,
      };
    }
  );

  await client.query(
    `
      with payload as (
        select * from json_populate_recordset(null::sms.tendlc_campaign_mno_metadata, $1::json) x
      )
      insert into sms.tendlc_campaign_mno_metadata (
        campaign_id,
        mno_id,
        mno,
        qualify,
        tpm,
        brand_tier,
        msg_class,
        mno_review,
        mno_support,
        min_msg_samples,
        req_subscriber_help,
        req_subscriber_optin,
        req_subscriber_optout,
        no_embedded_phone,
        no_embedded_link,
        extra
      )
      select
        $2 as campaign_id,
        payload.mno_id,
        payload.mno,
        payload.qualify,
        payload.tpm,
        payload.brand_tier,
        payload.msg_class,
        payload.mno_review,
        payload.mno_support,
        payload.min_msg_samples,
        payload.req_subscriber_help,
        payload.req_subscriber_optin,
        payload.req_subscriber_optout,
        payload.no_embedded_phone,
        payload.no_embedded_link,
        payload.extra
      from payload
      on conflict (campaign_id, mno_id) do update
      set
        mno = EXCLUDED.mno,
        qualify = EXCLUDED.qualify,
        tpm = EXCLUDED.tpm,
        brand_tier = EXCLUDED.brand_tier,
        msg_class = EXCLUDED.msg_class,
        mno_review = EXCLUDED.mno_review,
        mno_support = EXCLUDED.mno_support,
        min_msg_samples = EXCLUDED.min_msg_samples,
        req_subscriber_help = EXCLUDED.req_subscriber_help,
        req_subscriber_optin = EXCLUDED.req_subscriber_optin,
        req_subscriber_optout = EXCLUDED.req_subscriber_optout,
        no_embedded_phone = EXCLUDED.no_embedded_phone,
        no_embedded_link = EXCLUDED.no_embedded_link,
        extra = EXCLUDED.extra
    `,
    [JSON.stringify(mnoPayloads), payload.id]
  );
};
