import faker from 'faker';
import { PoolClient } from 'pg';

import { TollFreeUseCaseRecord } from '../../lib/types';
import { withReplicaMode } from '../helpers';
import {
  createPhoneNumberRequest,
  CreatePhoneNumberRequestOptions,
} from './phone-number-request';

type PhoneNumberRequest =
  | { phoneNumberRequestId?: string }
  | { phoneNumberRequest: CreatePhoneNumberRequestOptions };

export type CreateTollFreeUseCaseOptions = Omit<
  TollFreeUseCaseRecord,
  'id' | 'phone_number_request_id' | 'created_at' | 'updated_at'
> &
  PhoneNumberRequest & {
    triggers: boolean;
  };

export const createTollFreeUseCase = async (
  client: PoolClient,
  options: CreateTollFreeUseCaseOptions
): Promise<TollFreeUseCaseRecord> => {
  const insertOp = async (opClient: PoolClient) => {
    const phoneNumberRequestId =
      'phoneNumberRequestId' in options
        ? options.phoneNumberRequestId
        : 'phoneNumberRequest' in options
        ? await createPhoneNumberRequest(
            client,
            options.phoneNumberRequest
          ).then(({ id }) => id)
        : null;

    const {
      rows: [tollFreeUseCase],
    } = await opClient.query<TollFreeUseCaseRecord>(
      `
        insert into sms.toll_free_use_cases (
            client_id
          , sending_account_id
          , area_code
          , phone_number_request_id
          , phone_number_id
          , stakeholders
          , submitted_at
          , approved_at
          , throughput_interval
          , throughput_limit
        )
        values (
            $1
          , $2
          , $3
          , $4
          , $5
          , $6
          , $7
          , $8
          , $9
          , $10
        )
        returning *
      `,
      [
        options.client_id,
        options.sending_account_id,
        options.area_code,
        phoneNumberRequestId,
        options.phone_number_id,
        options.stakeholders,
        options.submitted_at,
        options.approved_at,
        options.throughput_interval,
        options.throughput_limit,
      ]
    );
    return tollFreeUseCase;
  };
  const result = options.triggers
    ? await insertOp(client)
    : await withReplicaMode(client, insertOp);
  return result;
};
