import { z } from 'zod';

import config from '../config';
import { findCandidateAreaCode } from '../lib/geo';
import { getTelcoClient } from '../lib/services';
import { persistCapacity } from '../lib/telco-data';
import { WrappableTask } from '../lib/types';
import { logger } from '../logger';
import { sendingAccountCache } from '../models/cache';

export const FIND_SUITABLE_AREA_CODES_IDENTIFIER = 'find-suitable-area-codes';

// tslint:disable-next-line variable-name
export const FindSuitableAreaCodesPayloadSchema = z
  .object({
    id: z.string().uuid(),
    center: z.string(),
    sending_account_id: z.string().uuid(),
  })
  .required();

export type FindSuitableAreaCodesPayload = z.infer<
  typeof FindSuitableAreaCodesPayloadSchema
>;

export const findSuitableAreaCodes: WrappableTask = async (
  client,
  rawPayload
) => {
  const payload = FindSuitableAreaCodesPayloadSchema.parse(rawPayload);
  const { id: sendingLocationId, center, sending_account_id } = payload;
  let suitableNumbersFound = 0;
  let offset = 0;
  let sameState = true;

  const areaCodesToUse: string[] = [];

  const saveResults = async () => {
    await client.query(
      'update sms.sending_locations set area_codes = $1 where id = $2',
      [areaCodesToUse, sendingLocationId]
    );
  };

  while (suitableNumbersFound < config.minSuitableNumbers) {
    const candidateAreaCode = await findCandidateAreaCode(
      client,
      center,
      offset,
      sameState
    );

    if (!candidateAreaCode) {
      // only warn and fail if we've already looked in other states
      if (!sameState) {
        await saveResults();

        logger.warn(
          'Urgent: cannot find enough numbers for sending location with payload',
          payload
        );

        return;
      }
      sameState = false;
      offset = 0;
      continue;
    }

    const sendingAccount = await sendingAccountCache.getSendingAccount(
      client,
      sending_account_id
    );
    const telcoClient = getTelcoClient(sendingAccount);
    const capacity = await telcoClient.estimateAreaCodeCapacity({
      areaCode: candidateAreaCode,
    });

    if (capacity > 0) {
      areaCodesToUse.push(candidateAreaCode);
      suitableNumbersFound += capacity;

      await persistCapacity(
        client,
        candidateAreaCode,
        sending_account_id,
        capacity
      );
    }

    offset += 1;
    await saveResults();
  }
};
