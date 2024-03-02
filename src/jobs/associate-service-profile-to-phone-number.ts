import { PoolClient } from 'pg';
import { z } from 'zod';

import { InvalidProfileConfigurationError } from '../lib/errors';
import { getTelcoClient } from '../lib/services';
import {
  PhoneNumberRecord,
  ProfileRecord,
  SendingLocationRecord,
} from '../lib/types';
import { profileConfigCache, sendingAccountCache } from '../models/cache';

export const ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER =
  'associate-service-profile-to-phone-number';

// tslint:disable-next-line variable-name
export const AssociateServiceProfileToNumberPayloadSchema = z
  .object({
    phone_number: z.string(),
  })
  .required();

export type AssociateServiceProfileToNumberPayload = z.infer<
  typeof AssociateServiceProfileToNumberPayloadSchema
>;

export type LookupInfo = Pick<PhoneNumberRecord, 'phone_number'> &
  Pick<SendingLocationRecord, 'profile_id'> &
  Pick<ProfileRecord, 'sending_account_id'>;

export const associateServiceProfileToNumber = async (
  client: PoolClient,
  rawPayload: unknown
) => {
  const payload =
    AssociateServiceProfileToNumberPayloadSchema.parse(rawPayload);
  const {
    rows: [info],
  } = await client.query<LookupInfo>(
    `
      select
        pn.phone_number,
        sl.profile_id,
        p.sending_account_id
      from sms.phone_numbers pn
      join sms.sending_locations sl on sl.id = pn.sending_location_id
      join sms.profiles p on p.id = sl.profile_id
      where
        pn.phone_number = $1
    `,
    [payload.phone_number]
  );

  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    info.sending_account_id
  );
  const { service_profile_id } = await profileConfigCache.getProfileConfig(
    client,
    info.profile_id
  );

  if (!service_profile_id) {
    throw new InvalidProfileConfigurationError(
      sendingAccount.service,
      sendingAccount.sending_account_id,
      'service_profile_id was null'
    );
  }

  const result = await getTelcoClient(sendingAccount).associateServiceProfile({
    phoneNumber: info.phone_number,
    serviceProfileId: service_profile_id,
  });

  return result;
};
