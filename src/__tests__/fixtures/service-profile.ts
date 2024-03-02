import faker from 'faker';
import { PoolClient } from 'pg';
import {
  ProfileServiceConfigurationRecord,
  TelnyxProfileServiceConfiguration,
  TwilioProfileServiceConfiguration,
} from '../../lib/types';

export interface CreateTwilioProfileServiceConfigurationOptions
  extends Pick<TwilioProfileServiceConfiguration, 'messaging_service_sid'> {}

export const createTwilioProfileServiceConfiguration = async (
  client: PoolClient,
  options: CreateTwilioProfileServiceConfigurationOptions
) => {
  const insertOp = async (opClient: PoolClient) => {
    const {
      rows: [serviceProfile],
    } = await opClient.query<ProfileServiceConfigurationRecord>(
      `
        with new_twilio_config as (
          insert into sms.twilio_profile_service_configurations (messaging_service_sid)
          values ($1)
          returning id
        )
        insert into sms.profile_service_configurations (twilio_configuration_id)
        select id
        from new_twilio_config
        returning *
      `,
      [options.messaging_service_sid ?? `MS${faker.random.alphaNumeric(32)}`]
    );
    return serviceProfile;
  };
  const result = await insertOp(client);
  return result;
};

export interface CreateTelnyxProfileServiceConfigurationOptions
  extends Partial<
    Pick<
      TelnyxProfileServiceConfiguration,
      'messaging_profile_id' | 'billing_group_id'
    >
  > {}

export const createTelnyxProfileServiceConfiguration = async (
  client: PoolClient,
  options: CreateTelnyxProfileServiceConfigurationOptions
) => {
  const insertOp = async (opClient: PoolClient) => {
    const {
      rows: [serviceProfile],
    } = await opClient.query<ProfileServiceConfigurationRecord>(
      `
          with new_telnyx_config as (
            insert into sms.telnyx_profile_service_configurations (messaging_profile_id, billing_group_id)
            values ($1, $2)
            returning id
          )
          insert into sms.profile_service_configurations (telnyx_configuration_id)
          select id
          from new_telnyx_config
          returning *
        `,
      [
        options.messaging_profile_id ?? faker.random.uuid(),
        options.billing_group_id ?? faker.random.uuid(),
      ]
    );
    return serviceProfile;
  };
  const result = await insertOp(client);
  return result;
};
