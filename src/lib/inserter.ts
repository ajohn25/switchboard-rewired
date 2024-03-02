import { PoolOrPoolClient } from '../db';
import { logger } from '../logger';
import { Tables } from './db-types';
import { SwitchboardEmitter } from './emitter';

interface ProfileIdKeyValuePair {
  profile_id?: string;
}

type ExcludeIfMissingProfileId<Table extends keyof Tables> =
  Tables[Table] extends ProfileIdKeyValuePair ? Table : never;

type TablesWithProfileId = {
  [Table in keyof Tables as ExcludeIfMissingProfileId<Table>]: Tables[Table];
};

/*
 * I extracted this into a function for 2 reasons:
 * 1 - to make inserts a little bit easier
 * 2 - so that in the future, we can automatically pool similar inserts into a table that insert the same columns
 * 		 by waiting a little grace period for the insert
 */
// type PartialBy<T, K extends keyof T> = Omit<T, K> & Partial<Pick<T, K>>;

export function insert<TableName extends keyof TablesWithProfileId>(
  client: PoolOrPoolClient,
  tableName: TableName,
  record: Omit<TablesWithProfileId[TableName], 'id'> &
    Partial<TablesWithProfileId[TableName]>
): Promise<TablesWithProfileId[TableName]>;

export function insert<TableName extends keyof Tables>(
  client: PoolOrPoolClient,
  tableName: TableName,
  record: Omit<Tables[TableName], 'id'> & Partial<Tables[TableName]>,
  profileId: string
): Promise<Tables[TableName]>;

export async function insert<TableName extends keyof Tables>(
  client: PoolOrPoolClient,
  tableName: TableName,
  record: Omit<Tables[TableName], 'id'>,
  maybeProfileId?: string
) {
  const profileId = maybeProfileId || (record as any).profile_id;

  const kv = Object.entries(record);

  const columnString = kv.map(([key, _]) => key).join(', ');
  const variablesString = kv.map((_, idx) => `$${idx + 1}`).join(',');
  const values = kv.map(([_, value]) => value);

  const queryString = `insert into sms.${tableName} (${columnString}) values (${variablesString}) returning *`;

  if (tableName === 'outbound_messages_routing') {
    logger.debug(`Inserting ${queryString}`, values);
  }

  const results = await client.query<Tables[TableName]>(queryString, values);

  const result = results.rows[0];

  SwitchboardEmitter.emit(profileId, `inserted:${tableName}`, result as any);

  return result;
}
