import { z } from 'zod';

import { getTelcoClient } from '../lib/services';
import { persistCapacity } from '../lib/telco-data';
import { WrappableTask } from '../lib/types';
import { sendingAccountCache } from '../models/cache';

export const ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER =
  'estimate-area-code-capacity';

// tslint:disable-next-line variable-name
export const EstimateAreaCodeCapacityPayloadSchema = z
  .object({
    area_codes: z.array(z.string()),
    sending_account_id: z.string().uuid(),
  })
  .required();

export type EstimateAreaCodeCapacityPayload = z.infer<
  typeof EstimateAreaCodeCapacityPayloadSchema
>;

/**
 * Fetch a count of phone number available for a given area code and service.
 * @param client PoolClient
 * @param payload Area code capacity payload (including sending profile)
 */
export const estimateAreaCodeCapacity: WrappableTask = async (
  client,
  rawPayload
) => {
  const payload = EstimateAreaCodeCapacityPayloadSchema.parse(rawPayload);
  const { area_codes, sending_account_id } = payload;

  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sending_account_id
  );
  const telcoClient = getTelcoClient(sendingAccount);

  await Promise.all(
    area_codes.map((areaCode) =>
      telcoClient
        .estimateAreaCodeCapacity({ areaCode })
        .then((capacity) =>
          persistCapacity(client, areaCode, sending_account_id, capacity)
        )
    )
  );
};
