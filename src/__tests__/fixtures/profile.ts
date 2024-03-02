import faker from 'faker';
import { PoolClient } from 'pg';

import {
  ProfileRecord,
  SendingAccountRecord,
  SendingLocationPurchasingStrategy,
  Service,
  TrafficChannel,
} from '../../lib/types';
import { withReplicaMode } from '../helpers';
import { createClient, CreateClientOptions } from './client';
import {
  createSendingAccount,
  CreateSendingAccountOptions,
} from './sending-account';
import {
  createTelnyxProfileServiceConfiguration,
  createTwilioProfileServiceConfiguration,
} from './service-profile';
import {
  createTenDlcCampaign,
  CreateTenDlcCampaignOptions,
} from './tendlc-campaign';
import {
  createTollFreeUseCase,
  CreateTollFreeUseCaseOptions,
} from './toll-free-use-case';

export type TollFreeUnion =
  | { channel?: TrafficChannel.GreyRoute }
  | ({ channel?: TrafficChannel.TenDlc } & (
      | { tenDlcCampaignId: string }
      | { tenDlcCampaign: CreateTenDlcCampaignOptions }
    ))
  | ({ channel: TrafficChannel.TollFree } & (
      | { tollFreeUseCaseId: string }
      | { tollFreeUseCase: CreateTollFreeUseCaseOptions }
    ));

export type CreateProfileOptions = Partial<
  Omit<
    ProfileRecord,
    | 'client_id'
    | 'sending_account_id'
    | 'profile_service_configuration_id'
    | 'toll_free_use_case_id'
    | 'tendlc_campaign_id'
    | 'channel'
    | 'active'
  >
> &
  TollFreeUnion & {
    triggers: boolean;
    client:
      | { type: 'existing'; id: string }
      | ({ type: 'create' } & CreateClientOptions);
    profile_service_configuration:
      | { type: 'existing'; id: string }
      | ({ type: 'create' } & {
          profile_service_configuration_id: string | null;
        });
    sending_account:
      | { type: 'existing'; id: string }
      | ({ type: 'create' } & CreateSendingAccountOptions);
  };

export const createProfile = async (
  client: PoolClient,
  options: CreateProfileOptions
) => {
  const clientId =
    options.client.type === 'existing'
      ? options.client.id
      : await createClient(client, options.client).then((res) => res.clientId);
  const sendingAccountId =
    options.sending_account.type === 'existing'
      ? options.sending_account.id
      : await createSendingAccount(client, options.sending_account).then(
          (res) => res.id
        );

  const createProfileServiceConfiguration = async (
    serviceProfileIdOp: string | null
  ) => {
    const {
      rows: [{ service }],
    } = await client.query<Pick<SendingAccountRecord, 'service'>>(
      `select service from sms.sending_accounts where id = $1`,
      [sendingAccountId]
    );

    if (service === Service.Twilio) {
      const profile = await createTwilioProfileServiceConfiguration(client, {
        messaging_service_sid: serviceProfileIdOp,
      });
      return profile;
    }
    if (service === Service.Telnyx) {
      const profile = await createTelnyxProfileServiceConfiguration(client, {
        messaging_profile_id: serviceProfileIdOp,
      });
      return profile;
    }
    if (service === Service.Bandwidth) {
      return undefined;
    }
    if (service === Service.Tcr) {
      return undefined;
    }
  };

  const profileServiceConfigurationId =
    options.profile_service_configuration.type === 'existing'
      ? options.profile_service_configuration.id
      : await createProfileServiceConfiguration(
          options.profile_service_configuration.profile_service_configuration_id
        ).then((res) => res?.id ?? null);

  const tollFreeUseCaseId =
    options.channel === TrafficChannel.TollFree
      ? 'tollFreeUseCaseId' in options
        ? options.tollFreeUseCaseId
        : await createTollFreeUseCase(client, options.tollFreeUseCase).then(
            ({ id }) => id
          )
      : null;

  const tenDlcCampaignId =
    options.channel === TrafficChannel.TenDlc
      ? 'tenDlcCampaignId' in options
        ? options.tenDlcCampaignId
        : await createTenDlcCampaign(client, {
            registrarSendingAccountId: sendingAccountId,
            registrarCampaignId: faker.random.uuid(),
          }).then((tenDlcCampaign) => tenDlcCampaign.campaignId)
      : null;

  const insertOp = async (opClient: PoolClient) => {
    const { rows } = await opClient.query<ProfileRecord>(
      `
        insert into sms.profiles (
          client_id,
          sending_account_id,
          display_name,
          channel,
          provisioned,
          reply_webhook_url,
          message_status_webhook_url,
          default_purchasing_strategy,
          voice_callback_url,
          profile_service_configuration_id,
          tendlc_campaign_id,
          toll_free_use_case_id
        )
        values (
          $1,
          $2,
          $3,
          $4,
          $5,
          $6,
          $7,
          $8,
          $9,
          $10,
          $11,
          $12
        )
        returning *
      `,
      [
        clientId,
        sendingAccountId,
        options.display_name ?? faker.company.companyName(),
        options.channel ?? TrafficChannel.GreyRoute,
        options.provisioned ?? false,
        options.reply_webhook_url ?? faker.internet.url(),
        options.message_status_webhook_url ?? faker.internet.url(),
        options.default_purchasing_strategy ??
          SendingLocationPurchasingStrategy.SameStateByDistance,
        options.voice_callback_url ?? null,
        profileServiceConfigurationId,
        tenDlcCampaignId ?? null,
        tollFreeUseCaseId,
      ]
    );
    return rows[0];
  };
  const result = options.triggers
    ? await insertOp(client)
    : await withReplicaMode(client, insertOp);
  return result;
};
