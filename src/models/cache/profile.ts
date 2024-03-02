import type { Redis } from 'ioredis';
import type { PoolClient } from 'pg';
import { z } from 'zod';

import { getRedis } from '../../lib/redis';
import { ProfileRecordSchema } from '../../lib/types';

// tslint:disable-next-line: variable-name
const ProfileConfigSchema = ProfileRecordSchema.extend({
  service_profile_id: z.string().nullable(),
}).required();

export type ProfileConfig = z.infer<typeof ProfileConfigSchema>;

// Switchboard does not operate in isolation -- Retool apps, Pipedream workflows, ad hoc scripts
// A 5 minute TTL balances timely eviction of stale data against a long enough TTL to provide value
// Autosending at 100 messages/second for 5 minutes = 30,000 send message workflows per profile id
const EXPIRATION_SECONDS = 60 * 5;

class ProfileConfigCache {
  public readonly KEY_PREFIX = 'v1|profile-config';
  private redis: Redis;

  constructor(redis: Redis) {
    this.redis = redis;
  }

  public resetCache() {
    this.redis.keys(this.genKey('*')).then((keys) => this.redis.del(keys));
  }

  public async getProfileConfig(
    client: PoolClient,
    profileId: string
  ): Promise<ProfileConfig> {
    const key = this.genKey(profileId);
    const cachedValue = await this.redis.get(key);

    if (!cachedValue) {
      const profileConfig = await this.fetchProfileConfig(client, profileId);
      await this.redis.set(
        key,
        JSON.stringify(profileConfig),
        'EX',
        EXPIRATION_SECONDS
      );
      return profileConfig;
    }
    {
      const profileConfig = ProfileConfigSchema.parse(JSON.parse(cachedValue));
      return profileConfig;
    }
  }

  private async fetchProfileConfig(
    client: PoolClient,
    profileId: string
  ): Promise<ProfileConfig> {
    const {
      rows: [profileConfig],
    } = await client.query<ProfileConfig>(
      `
        select
          profiles.id,
          profiles.client_id,
          profiles.sending_account_id,
          profiles.display_name,
          profiles.reply_webhook_url,
          profiles.message_status_webhook_url,
          profiles.default_purchasing_strategy,
          profiles.voice_callback_url,
          profiles.daily_contact_limit,
          profiles.throughput_interval::text,
          profiles.throughput_limit,
          profiles.channel,
          profiles.provisioned,
          profiles.disabled,
          profiles.active,
          profiles.toll_free_use_case_id,
          profiles.profile_service_configuration_id,
          profiles.tendlc_campaign_id,
          (case
            when sending_account.service = 'twilio' then twilio_configs.messaging_service_sid
            when sending_account.service = 'telnyx' then telnyx_configs.messaging_profile_id
          end) as service_profile_id
        from sms.profiles
        join sms.sending_accounts_as_json as sending_account
          on sending_account.id = sms.profiles.sending_account_id
        left join sms.profile_service_configurations configs on configs.id = profiles.profile_service_configuration_id
        left join sms.twilio_profile_service_configurations twilio_configs on twilio_configs.id = configs.twilio_configuration_id
        left join sms.telnyx_profile_service_configurations telnyx_configs on telnyx_configs.id = configs.telnyx_configuration_id
        where
          profiles.id = $1
      `,
      [profileId]
    );
    return profileConfig;
  }

  private genKey(suffix: string) {
    return `${this.KEY_PREFIX}:${suffix}`;
  }
}

export const profileConfigCache = new ProfileConfigCache(getRedis());
