import { Request, RequestHandler } from 'express';
import memoizee from 'memoizee';

import config from '../config';
import { db, sql } from '../db';
import { writeHistogram } from '../logger';
import { crypt } from './crypt';

const fetchClientIdFromToken = memoizee(
  async (token: string) => {
    let decryptedToken: string;
    try {
      decryptedToken = crypt.decrypt(token);
    } catch {
      // Invalid authentication token received
      return undefined;
    }

    const start = Date.now();

    const matchingClientIds = await db<{ id: string }>(
      sql`select id from billing.clients where billing.clients.access_token = ${decryptedToken}`
    );

    const end = Date.now();

    writeHistogram('api.fetch_client_from_db.run_time', end - start, [
      `client_id:${matchingClientIds[0]?.id ?? 'not_found'}`,
    ]);

    return matchingClientIds[0] && matchingClientIds[0].id;
  },
  {
    primitive: true,
    promise: true,
  }
);

const developmentClient = async () => {
  const results = await db<{ id: string }>(
    sql`
      insert into billing.clients (name)
      values ('Development')
      on conflict do nothing
      returning id
    `
  );

  if (results.length === 0) {
    const [{ id: clientId }] = await db<{ id: string }>(
      sql`
      select id from billing.clients
      where name = 'Development'
    `
    );

    return clientId;
  }

  return results[0].id;
};

export interface ClientAuthenticatedRequest extends Request {
  client: string;
}

export interface AdminAuthenticatedRequest extends Request {
  admin: boolean;
}

export interface GraphQlAuthenticatedRequest extends Request {
  auth: {
    role: string;
    'client.id'?: string;
  };
}

export const auth: { [key: string]: RequestHandler } = {
  admin: (req, res, next) => {
    const token = req.headers.token;
    if (token === undefined) {
      return res.status(401).json({ error: 'Must supply `token` header' });
    }

    if (token !== config.adminAccessToken) {
      return res.status(403).json({ error: 'Invalid token' });
    }

    (req as any).admin = true;
    return next();
  },
  client: async (req, res, next) => {
    const token = req.headers.token;
    if (token === undefined || Array.isArray(token)) {
      return res
        .status(401)
        .json({ error: 'Must supply single `token` header' });
    }

    const start = Date.now();
    const clientId = await fetchClientIdFromToken(token);
    const end = Date.now();

    writeHistogram('api.fetch_client_id.run_time', end - start, [
      `client_id:${clientId}`,
    ]);

    if (clientId === undefined) {
      return res.status(403).json({ error: 'Invalid token' });
    }

    (req as any).client = clientId;
    return next();
  },
  graphql: async (req, res, next) => {
    if (config.isDev) {
      (req as any).auth = {
        'client.id': await developmentClient(),
        role: 'client',
      };
      return next();
    }

    const token = req.headers.token;

    if (token === undefined || Array.isArray(token)) {
      return res
        .status(401)
        .json({ error: 'Must supply single `token` header' });
    }

    // Admin just needs role: admin
    if (token === config.adminAccessToken) {
      (req as any).auth = {
        role: 'admin',
      };

      return next();
    }

    const start = Date.now();
    const clientId = await fetchClientIdFromToken(token);
    const end = Date.now();

    writeHistogram('api.fetch_client_id.run_time', end - start, [
      `client_id:${clientId}`,
    ]);

    if (clientId === undefined) {
      return res.status(403).json({ error: 'Invalid token' });
    }

    (req as any).auth = {
      'client.id': clientId,
      role: 'client',
    };

    return next();
  },
};
