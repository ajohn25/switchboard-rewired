import express from 'express';

import { db, sql } from '../db';
import { auth, ClientAuthenticatedRequest } from '../lib/auth';
import { lookup } from '../lib/lookup';
import { normalize } from '../lib/utils';

const app = express();

app.get('/lookup/:number', auth.client, async (req, res) => {
  const authnReq = req as ClientAuthenticatedRequest;
  const rawNumber = authnReq.params.number;
  const phoneNumber = normalize(rawNumber);

  if (phoneNumber === 'invalid') {
    return res
      .status(400)
      .json({ error: `Invalid phone number: ${rawNumber}` });
  }

  const foundNumberInCache = await db(
    sql`
      select phone_number, carrier_name, phone_type
      from lookup.fresh_phone_data
      where phone_number = ${phoneNumber}
    `
  );

  if (foundNumberInCache.length === 0) {
    const result = await lookup(phoneNumber);
    const { carrier_name, phone_type } = result;

    await Promise.all([
      db(
        sql`
        insert into lookup.lookups (phone_number, carrier_name, phone_type, raw_result)
        values (
          ${phoneNumber}, ${carrier_name}, ${phone_type}, ${sql.json(result)}
        )
      `
      ),
      db(
        sql`
        insert into lookup.accesses (client_id, phone_number, state)
        values (${authnReq.client}, ${phoneNumber}, 'done');
      `
      ),
    ]);

    return res.json({ phone_number: phoneNumber, carrier_name, phone_type });
  }

  await db(
    sql`
      insert into lookup.accesses (client_id, phone_number, state)
      values (${authnReq.client}, ${phoneNumber}, 'done')
    `
  );

  return res.json(foundNumberInCache[0]);
});

export default app;
