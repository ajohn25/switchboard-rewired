import { z } from 'zod';

import { getTelcoClient } from '../lib/services';
import { WrappableTask } from '../lib/types';
import { sendingAccountCache } from '../models/cache';

export const SELL_NUMBER_IDENTIFIER = 'sell-number';

// tslint:disable-next-line variable-name
export const SellNumberPayloadSchema = z
  .object({
    id: z.string().uuid(),
    phone_number: z.string(),
    sending_account_id: z.string().uuid(),
  })
  .required();

export type SellNumberPayload = z.infer<typeof SellNumberPayloadSchema>;

export const sellNumber: WrappableTask = async (client, rawPayload) => {
  const payload = SellNumberPayloadSchema.parse(rawPayload);
  const { id: phoneNumberId, sending_account_id } = payload;
  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sending_account_id
  );
  await getTelcoClient(sendingAccount).sellNumber(payload);

  await client.query(
    'update sms.all_phone_numbers set sold_at = now() where id = $1',
    [phoneNumberId]
  );
};
