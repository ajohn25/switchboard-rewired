import faker from 'faker';
import { Pool, PoolClient } from 'pg';
import {
  createSendingAccount,
  createTenDlcCampaign,
} from '../__tests__/fixtures';
import {
  autoRollbackMiddleware,
  withPgMiddlewares,
} from '../__tests__/helpers';
import { TcrNock, TelnyxNock } from '../__tests__/nocks';
import config from '../config';
import { Service, TenDlcMnoMetadataRecord } from '../lib/types';
import {
  GET_MNO_METADATA_IDENTIFIER,
  getMnoMetadata,
} from './get-mno-metadata';

interface SetUpGetMnoMetadataOptions {
  tcrCampaignId?: string;
  registrarService: Service;
  registrarCampaignId: string;
}

const setUpGetMnoMetadata = async (
  client: PoolClient,
  options: SetUpGetMnoMetadataOptions
) => {
  const { tcrCampaignId, registrarService, registrarCampaignId } = options;
  const tcrSendingAccount = tcrCampaignId
    ? await createSendingAccount(client, {
        triggers: true,
        service: Service.Tcr,
      })
    : undefined;

  const registrarSendingAccount = await createSendingAccount(client, {
    triggers: true,
    service: registrarService,
  });

  const { campaignId } = await createTenDlcCampaign(client, {
    tcrSendingAccountId: tcrSendingAccount?.id,
    tcrCampaignId,
    registrarSendingAccountId: registrarSendingAccount.id,
    registrarCampaignId,
  });

  return campaignId;
};

const runGetMnoMetadataJob = async (
  client: PoolClient,
  tenDlcCampaignId: string
) => {
  const {
    rows: [job],
  } = await client.query<{ payload: { id: string } }>(
    `select * from graphile_worker.add_job('${GET_MNO_METADATA_IDENTIFIER}', $1::json)`,
    [{ id: tenDlcCampaignId }]
  );

  await getMnoMetadata(client, job.payload);
};

const getMnoMetadataRecords = async (
  client: PoolClient,
  tenDlcCampaignId: string
) => {
  const { rows } = await client.query<TenDlcMnoMetadataRecord>(
    `select * from sms.tendlc_campaign_mno_metadata where campaign_id = $1`,
    [tenDlcCampaignId]
  );
  return rows;
};

describe(GET_MNO_METADATA_IDENTIFIER, () => {
  let pool: Pool;

  beforeAll(() => {
    pool = new Pool({ connectionString: config.databaseUrl });
  });

  afterAll(() => {
    return pool.end();
  });

  it('should return the mno metadata for a telnyx-registered campaign', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const tenDlcCampaignId = await setUpGetMnoMetadata(client, {
        registrarService: Service.Telnyx,
        registrarCampaignId: faker.random.uuid(),
      });

      await TelnyxNock.getMNOMetadata();

      await runGetMnoMetadataJob(client, tenDlcCampaignId);

      const mnoMetadata = await getMnoMetadataRecords(client, tenDlcCampaignId);

      expect(mnoMetadata).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ mno_id: '10017' }),
          expect.objectContaining({ mno_id: '10035' }),
          expect.objectContaining({ mno_id: '10037' }),
          expect.objectContaining({ mno_id: '10038' }),
        ])
      );
    });
  });

  it('should return the mno metadata for a tcr-registered bandwidth campaign', async () => {
    await withPgMiddlewares(pool, [autoRollbackMiddleware], async (client) => {
      const tenDlcCampaignId = await setUpGetMnoMetadata(client, {
        tcrCampaignId: faker.random.uuid(),
        registrarService: Service.Telnyx,
        registrarCampaignId: faker.random.uuid(),
      });

      await TcrNock.getMNOMetadata();

      await runGetMnoMetadataJob(client, tenDlcCampaignId);

      const mnoMetadata = await getMnoMetadataRecords(client, tenDlcCampaignId);

      expect(mnoMetadata).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ mno_id: '10017' }),
          expect.objectContaining({ mno_id: '10035' }),
          expect.objectContaining({ mno_id: '10037' }),
          expect.objectContaining({ mno_id: '10038' }),
        ])
      );
    });
  });
});
