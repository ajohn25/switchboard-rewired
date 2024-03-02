import express from 'express';
import { Pool } from 'pg';
import telnyx from 'telnyx';

import config from '../config';
import { AdminAuthenticatedRequest, auth } from '../lib/auth';
import { crypt } from '../lib/crypt';
import { SendingAccount, Service } from '../lib/types';
import { errToObj, logger } from '../logger';

const app = express();
const pool = new Pool({ connectionString: config.databaseUrl });

interface SendingLocationPayload {
  center: string;
  name?: string;
}

interface ProfilePayload {
  reply_webhook_url: string;
  message_status_webhook_url: string;
  template_sending_account_id: string;
  sending_locations?: SendingLocationPayload[];
  name?: string;
  url_shortener_domain?: string;
}

export interface RegisterPayload {
  name: string;
  profiles?: ProfilePayload[];
}

interface RegisterResponse {
  client_id: string;
  access_token: string;
  profile_ids: string[];
}

const validatePayload = (payload: RegisterPayload) => {
  if (!payload.name) throw new Error("missing client 'name'");

  if (!payload.profiles || payload.profiles.length < 1) {
    return;
  }

  payload.profiles.forEach((profile, profileIndex) => {
    if (!profile.reply_webhook_url) {
      throw new Error(`profile ${profileIndex} missing 'reply_webhook_url'`);
    }

    if (!profile.message_status_webhook_url) {
      throw new Error(
        `profile ${profileIndex} missing 'message_status_webhook_url'`
      );
    }

    if (!profile.template_sending_account_id) {
      throw new Error(
        `profile ${profileIndex} missing 'template_sending_account_id'`
      );
    }

    if (profile.sending_locations && profile.sending_locations.length > 0) {
      profile.sending_locations.forEach((location, locationIndex) => {
        if (!location.center) {
          throw new Error(
            `profile ${profileIndex} sending location ${locationIndex} missing 'center'`
          );
        }
      });
    }
  });
};

interface CreateProfilePayload {
  baseAccount: SendingAccount;
  newAccount: {
    profileName: string;
    sendingAccountId: string;
    urlShortenerDomain?: string;
  };
}

export const setUpProfile = async (payload: CreateProfilePayload) => {
  const { baseAccount, newAccount } = payload;
  const { profileName, sendingAccountId, urlShortenerDomain } = newAccount;

  if (baseAccount.service === Service.Telnyx) {
    const telnyxCredentials = baseAccount.telnyx_credentials!;
    const apiKey = crypt.decrypt(telnyxCredentials.encrypted_api_key);
    const urlShortenerSettings =
      urlShortenerDomain !== undefined
        ? {
            domain: urlShortenerDomain,
            prefix: '',
            replace_blacklist_only: true,
            send_webhooks: false,
          }
        : null;
    const profilePayload = {
      enabled: true,
      name: profileName,
      number_pool_settings: null,
      url_shortener_settings: urlShortenerSettings,
      webhook_api_version: '2',
      webhook_failover_url: '',
      webhook_url: `https://numbers.assemble.live/hooks/reply/${sendingAccountId}`,
    };
    const telnyxClient = telnyx(apiKey);
    const { data: messagingProfile } =
      await telnyxClient.messagingProfiles.create(profilePayload);
    return messagingProfile;
  }

  throw new Error('invalid base sending account');
};

app.post('/register', auth.admin, async (req, res) => {
  const payload: RegisterPayload = (req as AdminAuthenticatedRequest).body;
  const client = await pool.connect();

  try {
    validatePayload(payload);
  } catch (err) {
    const errMessage = err instanceof Error ? err.message : 'unknown';
    return res.status(400).send({ errors: [errMessage] });
  }

  const { name: clientName, profiles = [] } = payload;

  await client.query('begin');

  try {
    const {
      rows: [{ id: clientId, access_token }],
    } = await client.query(
      'insert into billing.clients (name) values ($1) returning id, access_token',
      [clientName]
    );

    const response: RegisterResponse = {
      client_id: clientId,
      access_token: crypt.encrypt(access_token),
      profile_ids: [],
    };

    for (const profile of profiles) {
      const {
        rows: [sendingAccount],
      } = await client.query<SendingAccount>(
        `
            select
              id as sending_account_id,
              service,
              to_json(twilio_credentials) as twilio_credentials,
              to_json(telnyx_credentials) as telnyx_credentials
            from sms.sending_accounts
            where id = $1
          `,
        [profile.template_sending_account_id]
      );

      const profileName = profile.name || clientName;

      const newProfile = await setUpProfile({
        baseAccount: sendingAccount,
        newAccount: {
          profileName,
          sendingAccountId: sendingAccount.sending_account_id,
          urlShortenerDomain: profile.url_shortener_domain,
        },
      });

      const {
        rows: [{ id: telnyxProfileServiceConfigurationId }],
      } = await client.query<{ id: string }>(
        `insert into sms.telnyx_profile_service_configurations (messaging_profile_id) values ($1) returning id`,
        [newProfile.id]
      );

      const {
        rows: [{ id: serviceProfileId }],
      } = await client.query<{ id: string }>(
        `insert into sms.profile_service_configurations (telnyx_configuration_id) values ($1) returning id`,
        [telnyxProfileServiceConfigurationId]
      );

      const {
        rows: [{ id: profileId }],
      } = await client.query(
        `
            insert into sms.profiles (
              client_id,
              channel,
              display_name,
              reply_webhook_url,
              message_status_webhook_url,
              sending_account_id,
              profile_service_configuration_id
            )
            values ($1, $2, $3, $4, $5, $6, $7)
            returning id
          `,
        [
          clientId,
          'grey-route',
          profileName,
          profile.reply_webhook_url,
          profile.message_status_webhook_url,
          sendingAccount.sending_account_id,
          serviceProfileId,
        ]
      );

      for (const sendingLocation of profile.sending_locations || []) {
        const locationName = sendingLocation.name || profileName;
        await client.query(
          'insert into sms.sending_locations (profile_id, reference_name, center) values ($1, $2, $3)',
          [profileId, locationName, sendingLocation.center]
        );
      }

      response.profile_ids.push(profileId);
    }

    await client.query('commit');
    return res.json(response);
  } catch (err) {
    await client.query('rollback');
    logger.error('error registering client: ', errToObj(err));
    const errMessage = err instanceof Error ? err.message : 'unknown';
    return res.status(500).json({ error: errMessage });
  }
});

export default app;
