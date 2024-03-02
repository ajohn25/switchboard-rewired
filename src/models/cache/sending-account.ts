import type { Redis } from 'ioredis';
import type { PoolClient } from 'pg';
import { z } from 'zod';

import { getRedis } from '../../lib/redis';
import { SendingAccount, SendingAccountRecordSchema } from '../../lib/types';

// tslint:disable-next-line: variable-name
const CachedSendingAccountSchema = SendingAccountRecordSchema.omit({
  run_cost_backfills: true,
});
type CachedSendingAccount = z.infer<typeof CachedSendingAccountSchema>;

const EXPIRATION_SECONDS = 60 * 5;

class SendingAccountCache {
  public readonly KEY_PREFIX = 'v1|sending-account';

  private redis: Redis;

  constructor(redis: Redis) {
    this.redis = redis;
  }

  public resetCache() {
    this.redis.keys(this.genKey('*')).then((keys) => this.redis.del(keys));
  }

  public async getSendingAccount(
    client: PoolClient,
    sendingAccountId: string
  ): Promise<SendingAccount> {
    const key = this.genKey(sendingAccountId);
    const cachedSendingAccount = await this.redis.get(key);

    if (!cachedSendingAccount) {
      const sendingAccountRecord = await this.fetchSendingAccount(
        client,
        sendingAccountId
      );
      await this.redis.set(
        key,
        JSON.stringify(sendingAccountRecord),
        'EX',
        EXPIRATION_SECONDS
      );

      const sendingAccount = this.formatSendingAccount(sendingAccountRecord);
      return sendingAccount;
    }
    {
      const sendingAccountRecord = CachedSendingAccountSchema.parse(
        JSON.parse(cachedSendingAccount)
      );
      const sendingAccount = this.formatSendingAccount(sendingAccountRecord);
      return sendingAccount;
    }
  }

  private async fetchSendingAccount(
    client: PoolClient,
    sendingAccountId: string
  ): Promise<CachedSendingAccount> {
    const {
      rows: [sendingAccountRecord],
    } = await client.query<CachedSendingAccount>(
      `select * from sms.sending_accounts_as_json where id = $1`,
      [sendingAccountId]
    );
    return sendingAccountRecord;
  }

  private genKey(suffix: string) {
    return `${this.KEY_PREFIX}:${suffix}`;
  }

  private formatSendingAccount(
    sendingAccountRecord: CachedSendingAccount
  ): SendingAccount {
    const { id, ...remainder } = sendingAccountRecord;
    const sendingAccount = {
      sending_account_id: id,
      ...remainder,
    };
    return sendingAccount;
  }
}

export const sendingAccountCache = new SendingAccountCache(getRedis());
