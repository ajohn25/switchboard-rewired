import faker from 'faker';
import { PoolClient } from 'pg';

import { crypt } from '../../lib/crypt';
import { InvalidServiceError } from '../../lib/errors';
import { SendingAccount, SendingAccountRecord, Service } from '../../lib/types';
import { withReplicaMode } from '../helpers';

export interface CreateSendingAccountOptions
  extends Pick<SendingAccount, 'service'> {
  displayName?: string;
  triggers: boolean;
}

const createCredentials = (service: Service): string[] => {
  switch (service) {
    case Service.Telnyx: {
      return [
        faker.random.alphaNumeric(20),
        crypt.encrypt(faker.random.alphaNumeric(32)),
      ];
    }
    case Service.Twilio: {
      return [
        `AC${faker.random.alphaNumeric(32)}`,
        crypt.encrypt(faker.random.alphaNumeric(32)),
      ];
    }
    case Service.Bandwidth: {
      return [
        faker.random.number(10000).toString(),
        faker.internet.userName(),
        crypt.encrypt(faker.random.alphaNumeric(32)),
        faker.random.number(10000).toString(),
        faker.random.number(10000).toString(),
        faker.random.uuid(),
        faker.internet.userName(),
        crypt.encrypt(faker.random.alphaNumeric(32)),
      ];
    }
    case Service.Tcr: {
      return [
        faker.internet.userName(),
        faker.random.uuid(),
        crypt.encrypt(faker.random.alphaNumeric(32)),
      ];
    }
    default:
      throw new InvalidServiceError(service);
  }
};

export const createSendingAccount = async (
  client: PoolClient,
  options: CreateSendingAccountOptions
) => {
  const insertOp = async (opClient: PoolClient) => {
    const credsColName = `${options.service}_credentials`;
    const credsVals = createCredentials(options.service);
    const {
      rows: [{ id: sendingAccountId }],
    } = await opClient.query<{ id: string }>(
      `
        insert into sms.sending_accounts (display_name, service, ${credsColName})
        values ($1, $2, $3)
        returning id
      `,
      [
        options.displayName ?? faker.company.companyName(),
        options.service,
        `(${credsVals.join(',')})`,
      ]
    );

    const {
      rows: [sendingAccount],
    } = await opClient.query<SendingAccountRecord>(
      `select * from sms.sending_accounts_as_json where id = $1`,
      [sendingAccountId]
    );

    return sendingAccount;
  };
  const result = options.triggers
    ? await insertOp(client)
    : await withReplicaMode(client, insertOp);
  return result;
};
