import faker from 'faker';
import { PoolClient } from 'pg';

import { FullPhoneNumberRecord } from '../../lib/types';

export interface CreatePhoneNumberOptions
  extends Pick<FullPhoneNumberRecord, 'sending_location_id'>,
    Partial<Pick<FullPhoneNumberRecord, 'phone_number' | 'cordoned_at'>> {}

export const createPhoneNumber = async (
  client: PoolClient,
  options: CreatePhoneNumberOptions
) => {
  const insertOp = async (opClient: PoolClient) => {
    const {
      rows: [phoneNumber],
    } = await opClient.query<FullPhoneNumberRecord>(
      `
          insert into sms.all_phone_numbers (sending_location_id, phone_number, cordoned_at)
          values ($1, $2, $3)
          returning *
        `,
      [
        options.sending_location_id,
        options.phone_number ?? faker.phone.phoneNumber('+1##########'),
        options.cordoned_at ?? null,
      ]
    );
    return phoneNumber;
  };
  const result = await insertOp(client);
  return result;
};
