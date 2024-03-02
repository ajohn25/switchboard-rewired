import faker from 'faker';
import { PoolClient } from 'pg';

import {
  SendingLocationPurchasingStrategy,
  SendingLocationRecord,
  Service,
} from '../../lib/types';
import { withReplicaMode } from '../helpers';
import { createProfile, CreateProfileOptions } from './profile';

export interface CreateSendingLocationOptions
  extends Pick<SendingLocationRecord, 'center'>,
    Partial<
      Pick<
        SendingLocationRecord,
        | 'reference_name'
        | 'area_codes'
        | 'decomissioned_at'
        | 'purchasing_strategy'
        | 'state'
        | 'location'
      >
    > {
  triggers: boolean;
  profile:
    | { type: 'existing'; id: string }
    | { type: 'fast'; service: Service }
    | ({ type: 'create' } & CreateProfileOptions);
}

export const createSendingLocation = async (
  client: PoolClient,
  options: CreateSendingLocationOptions
) => {
  const profileId =
    options.profile.type === 'existing'
      ? options.profile.id
      : options.profile.type === 'fast'
      ? await createProfile(client, {
          client: { type: 'create' },
          sending_account: {
            service: options.profile.service,
            triggers: options.triggers,
            type: 'create',
          },
          profile_service_configuration: {
            type: 'create',
            profile_service_configuration_id:
              options.profile.service === Service.Twilio
                ? `MS${faker.random.alphaNumeric(30)}`
                : faker.random.uuid(),
          },
          triggers: options.triggers,
        }).then((res) => res.id)
      : await createProfile(client, options.profile).then((res) => res.id);
  const insertOp = async (opClient: PoolClient) => {
    const { rows } = await opClient.query<SendingLocationRecord>(
      `
        insert into sms.sending_locations (
          profile_id,
          reference_name,
          area_codes,
          center,
          decomissioned_at,
          purchasing_strategy,
          state,
          location
        )
        values ($1, $2, $3, $4, $5, $6, $7, $8)
        returning *
      `,
      [
        profileId,
        options.reference_name ?? faker.company.companyName(),
        options.area_codes ?? null,
        options.center,
        options.decomissioned_at ?? null,
        options.purchasing_strategy ??
          SendingLocationPurchasingStrategy.SameStateByDistance,
        options.state ?? null,
        options.location ?? null,
      ]
    );
    return rows[0];
  };

  const result = options.triggers
    ? await insertOp(client)
    : await withReplicaMode(client, insertOp);
  return result;
};
