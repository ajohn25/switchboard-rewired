import { makeWrapResolversPlugin } from 'graphile-utils';
import { Client } from 'pg';

import { withRole, withSavepoint } from '../../lib/db';
import { profiles, traffic_channel } from '../../lib/db-types';

const ID_ALIAS = '$sending_location_id';

export default makeWrapResolversPlugin({
  Mutation: {
    createSendingLocation: {
      requires: {
        childColumns: [{ column: 'id', alias: ID_ALIAS }],
      },
      async resolve(resolver, source, args, context, resolveInfo) {
        const pgClient: Client = context.pgClient;

        return withSavepoint(
          pgClient,
          'provision_sending_location',
          async (client) => {
            const result = await resolver(source, args, context, resolveInfo);
            const sendingLocationId = result.data[ID_ALIAS];

            const {
              rows: [{ id: profileId, channel }],
            } = await client.query<Pick<profiles, 'id' | 'channel'>>(
              `select id, channel from sms.profiles where id = (select profile_id from sms.sending_locations where id = $1)`,
              [sendingLocationId]
            );

            switch (channel) {
              case traffic_channel.GreyRoute:
                return result;
              case traffic_channel.TollFree:
                throw new Error(
                  'Cannot create ad hoc sending location for toll-free profile!'
                );
              case traffic_channel['10DLC']: {
                // The `client` role has limited access to tables. Become the postgres role to kick off phone number provisioning
                return withRole(client, 'postgres', async (postgresClient) => {
                  const { rowCount } = await postgresClient.query(
                    `
                      insert into sms.phone_number_requests (sending_location_id, area_code)
                      select id, area_codes[1]
                      from sms.sending_locations
                      where true
                        and id = $1
                        and area_codes[1] is not null
                        and (
                          select count(*)
                          from sms.phone_number_requests
                          where sending_location_id in (
                            select id from sms.sending_locations where profile_id = $2
                          )
                        ) < 49
                      returning 1
                    `,
                    [sendingLocationId, profileId]
                  );
                  if (rowCount !== 1) {
                    throw new Error(
                      `Expected 1 new phone number request for 10DLC profile but got ${rowCount}. The 10DLC campaign connected to this profile may be at its active phone number limit.`
                    );
                  }
                  return result;
                });
              }
            }
          }
        );
      },
    },
  },
});
