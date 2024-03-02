import { PoolClient } from 'pg';

import { PhoneNumberRequestRecord, Service } from '../../lib/types';
import { withReplicaMode } from '../helpers';
import {
  createSendingLocation,
  CreateSendingLocationOptions,
} from './sending-location';

export interface CreatePhoneNumberRequestOptions
  extends Partial<
    Pick<
      PhoneNumberRequestRecord,
      | 'phone_number'
      | 'commitment_count'
      | 'service_order_id'
      | 'tendlc_campaign_id'
      | 'service_order_completed_at'
      | 'service_profile_associated_at'
      | 'service_10dlc_campaign_associated_at'
    >
  > {
  triggers: boolean;
  sending_location:
    | { type: 'existing'; id: string }
    | { type: 'fast'; service: Service }
    | ({ type: 'create' } & CreateSendingLocationOptions);
  area_code: string;
}

export const createPhoneNumberRequest = async (
  client: PoolClient,
  options: CreatePhoneNumberRequestOptions
) => {
  const sendingLocationId =
    options.sending_location.type === 'existing'
      ? options.sending_location.id
      : options.sending_location.type === 'fast'
      ? await createSendingLocation(client, {
          center: '11238',
          profile: { type: 'fast', service: options.sending_location.service },
          triggers: options.triggers,
        }).then((res) => res.id)
      : await createSendingLocation(client, options.sending_location).then(
          (res) => res.id
        );

  const insertOp = async (opClient: PoolClient) => {
    const { rows } = await opClient.query<PhoneNumberRequestRecord>(
      `
        with sending_account as (
          select service
          from sms.sending_accounts sa
          join sms.profiles p on p.sending_account_id = sa.id
          join sms.sending_locations sl on sl.profile_id = p.id
          where sl.id = $1
        )
        insert into sms.phone_number_requests (
          sending_location_id,
          area_code,
          phone_number,
          commitment_count,
          service_order_id,
          service,
          tendlc_campaign_id,
          service_order_completed_at,
          service_profile_associated_at,
          service_10dlc_campaign_associated_at
        )
        select
          $1,
          $2,
          $3,
          $4,
          $5,
          service,
          $6,
          $7,
          $8,
          $9
        from sending_account
        returning *
      `,
      [
        sendingLocationId,
        options.area_code,
        options.phone_number ?? null,
        options.commitment_count ?? 0, // No way to do `coalsce($4, default)`, sadly
        options.service_order_id ?? null,
        options.tendlc_campaign_id ?? null,
        options.service_order_completed_at ?? null,
        options.service_profile_associated_at ?? null,
        options.service_10dlc_campaign_associated_at ?? null,
      ]
    );
    return rows[0];
  };

  const result = options.triggers
    ? await insertOp(client)
    : await withReplicaMode(client, insertOp);
  return result;
};
