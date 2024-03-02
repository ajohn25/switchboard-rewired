import promisePool from '@supercharge/promise-pool';
import { JobHelpers, Task } from 'graphile-worker';
import twilio from 'twilio';
import { z } from 'zod';

import { crypt } from '../lib/crypt';
import { SendingAccountRecordSchema } from '../lib/types';

export const BACKFILL_COST_IDENTIFIER = 'backfill-cost';

// tslint:disable-next-line: variable-name
const BackfillCostPayloadSchema = SendingAccountRecordSchema.pick({
  twilio_credentials: true,
}).extend({
  starting_at: z.string(),
  ending_at: z.string(),
  from_number: z.string(),
  concurrency: z.number().int().optional(),
});

export type BackfillCostPayload = z.infer<typeof BackfillCostPayloadSchema>;

const DEFAULT_CONCURRENCY = 10;

export const backfillCost: Task = async (rawPayload, helpers) => {
  const payload = BackfillCostPayloadSchema.parse(rawPayload);

  if (payload.twilio_credentials === null) {
    throw new Error(`Twilio credentials null!`);
  }

  const instance = twilio(
    payload.twilio_credentials.account_sid,
    crypt.decrypt(payload.twilio_credentials.encrypted_auth_token)
  );

  const opts = {
    dateSentAfter: new Date(payload.starting_at),
    dateSentBefore: new Date(payload.ending_at),
    from: payload.from_number,
  };

  const messages = await instance.messages.list(opts);

  const outboundMessagesWithPrice = messages.filter(
    (m) => m.price !== null && m.direction === 'outbound-api'
  );

  const result = await promisePool
    .withConcurrency(payload.concurrency || DEFAULT_CONCURRENCY)
    .for(outboundMessagesWithPrice)
    .process(async (m) => {
      await updateOutboundCostByServiceId(helpers, m.sid, m.price);
    });

  if (result.errors.length > 0) {
    throw result.errors;
  }
};

const updateOutboundCostByServiceId = async (
  helpers: JobHelpers,
  serviceId: string,
  price: string
) => {
  const cost = parseFloat(price) * -1 * 100;

  // Attempt to find telco entry
  const { rows: telcoRows } = await helpers.query(
    `select id from sms.outbound_messages_telco where service_id = $1`,
    [serviceId]
  );

  if (telcoRows.length > 0) {
    helpers.logger.debug(
      `Updating telco with id ${telcoRows[0].id} with cost ${cost}`
    );
    const result = await helpers.query(
      `update sms.outbound_messages_telco set cost_in_cents = $2 where id = $1`,
      [telcoRows[0].id, cost]
    );
    return result;
  }

  const { rows: oldRows } = await helpers.query(
    `select id from sms.outbound_messages where service_id = $1`,
    [serviceId]
  );

  if (oldRows.length > 0) {
    helpers.logger.debug(
      `Updating old with id ${oldRows[0].id} with cost ${cost}`
    );
    return helpers.query(
      `update sms.outbound_messages set cost_in_cents = $2 where id = $1`,
      [oldRows[0].id, cost]
    );
  }

  throw new Error(
    `Message not found. service_id: ${serviceId}, price: ${cost}`
  );
};
