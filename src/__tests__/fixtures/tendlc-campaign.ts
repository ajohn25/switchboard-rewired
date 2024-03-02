import faker from 'faker';
import { PoolClient } from 'pg';

import { TenDlcCampaignRecord } from '../../lib/types';

export interface CreateTenDlcCampaignOptions {
  tcrSendingAccountId?: string;
  tcrCampaignId?: string;
  registrarSendingAccountId?: string;
  registrarCampaignId?: string;
}

export const createTenDlcCampaign = async (
  client: PoolClient,
  options: CreateTenDlcCampaignOptions
) => {
  const {
    rows: [{ id: campaignId }],
  } = await client.query<Pick<TenDlcCampaignRecord, 'id'>>(
    `
      insert into sms.tendlc_campaigns (tcr_account_id, tcr_campaign_id, registrar_account_id, registrar_campaign_id)
      values ($1, $2, $3, $4)
      returning id
    `,
    [
      options.tcrSendingAccountId ?? null,
      options.tcrCampaignId ?? null,
      options.registrarSendingAccountId ?? null,
      options.registrarCampaignId ?? null,
    ]
  );
  return { campaignId };
};
