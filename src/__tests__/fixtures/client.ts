import faker from 'faker';
import { PoolClient } from 'pg';

import { ClientRecord } from '../../lib/types';

export interface CreateClientOptions {
  name?: string;
}

export const createClient = async (
  client: PoolClient,
  options: CreateClientOptions
) => {
  const {
    rows: [{ id: clientId }],
  } = await client.query<Pick<ClientRecord, 'id'>>(
    `insert into billing.clients (name) values ($1) returning id`,
    [options.name || `${faker.company.companyName()}-${Math.random() * 1e6}`]
  );
  return { clientId };
};
