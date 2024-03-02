import { PoolClient } from 'pg';
import { z } from 'zod';

import { getTelcoClient } from '../lib/services';
import { sendingAccountCache } from '../models/cache';
import { wrapWithQueueNextStepInPurchaseNumberPipeline } from './queue-next-step-in-purchase-number-pipeline';
import { PurchaseNumberPayloadSchema } from './schema-validation';

export const POLL_NUMBER_ORDER_IDENTIFIER = 'poll-number-order';

// tslint:disable-next-line variable-name
export const PollNumberOrderPayloadSchema = PurchaseNumberPayloadSchema.pick({
  id: true,
  sending_account_id: true,
}).extend({
  service_order_id: z.string().uuid(),
});

export type PollNumberOrderPayload = z.infer<
  typeof PollNumberOrderPayloadSchema
>;

export const pollNumberOrder = wrapWithQueueNextStepInPurchaseNumberPipeline(
  POLL_NUMBER_ORDER_IDENTIFIER,
  async (client: PoolClient, rawPayload) => {
    const payload = PollNumberOrderPayloadSchema.parse(rawPayload);
    const { id: phoneNumberRequestId, sending_account_id } = payload;
    const sendingAccount = await sendingAccountCache.getSendingAccount(
      client,
      sending_account_id
    );
    await getTelcoClient(sendingAccount).pollNumberOrder({
      serviceOrderId: payload.service_order_id,
    });

    await client.query(
      `update sms.phone_number_requests set service_order_completed_at = now() where id = $1`,
      [phoneNumberRequestId]
    );
  }
);
