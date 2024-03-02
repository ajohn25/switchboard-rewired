import { PoolClient } from 'pg';

import { PoolOrPoolClient } from '../db';
import { sendingAccountCache } from '../models/cache';
import { getTelcoClient } from './services';

export const findCandidateAreaCode = async (
  client: PoolOrPoolClient,
  center: string,
  offset: number,
  sameState: boolean
): Promise<string> => {
  /**
   * This query joins zip_area_code to zip_locations
   * and uses a min + a group by to get the closest zip to the center
   * for each unique area code
   *
   * Warning: it does a sequential scan on zip_locations
   * This is fine for the moment and only takes 15ms
   * To make it use an index, we'd have to propagate location and state to geo.zip_area_codes
   */
  const { rows } = await client.query(
    `
      with center_location as (
        select location, state
        from geo.zip_locations
        where geo.zip_locations.zip = $1
      )
      select
        area_code,
        min(
          geo.zip_locations.location <-> ( select location from center_location )
        ) as distance
      from geo.zip_area_codes
      join geo.zip_locations
        on geo.zip_area_codes.zip = geo.zip_locations.zip
      where ${
        sameState
          ? `geo.zip_locations.state = ( select state from center_location )`
          : `geo.zip_locations.state <> ( select state from center_location )`
      }
      group by area_code
      order by 2
      limit 1
      offset $2
    `,
    [center, offset]
  );

  return rows.map((row) => row.area_code)[0];
};

export const findOneSuitableAreaCode = async (
  client: PoolClient,
  payload: { center: string; sending_account_id: string }
): Promise<string | null> => {
  const { center, sending_account_id } = payload;
  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sending_account_id
  );

  let offset = 0;

  while (true) {
    const candidateAreaCode = await findCandidateAreaCode(
      client,
      center,
      offset,
      true
    );

    if (!candidateAreaCode) {
      return null;
    }

    const capacity = await getTelcoClient(
      sendingAccount
    ).estimateAreaCodeCapacity({
      areaCode: candidateAreaCode,
    });

    if (capacity > 0) {
      return candidateAreaCode;
    }

    offset += 1;
  }
};
