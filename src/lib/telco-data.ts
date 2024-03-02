import { PoolClient } from 'pg';

export const persistCapacity = async (
  client: PoolClient,
  areaCode: string,
  sendingAccountId: string,
  capacity: number
) => {
  await client.query(
    `
      insert into sms.area_code_capacities (area_code, sending_account_id, capacity)
      values ($1, $2, $3)
      on conflict (area_code, sending_account_id)
      do update set capacity = EXCLUDED.capacity,  last_fetched_at = CURRENT_TIMESTAMP;
    `,
    [areaCode, sendingAccountId, capacity]
  );
};
