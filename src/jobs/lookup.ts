import { z } from 'zod';

import { lookup } from '../lib/lookup';
import { WrappableTask } from '../lib/types';

export const LOOKUP_IDENTIFIER = 'lookup';

const VALID_PHONE_TYPES = ['landline', 'mobile', 'voip'];

// tslint:disable-next-line variable-name
export const LookupPayloadSchema = z
  .object({
    access_id: z.string(),
    phone_number: z.string(),
  })
  .required();

export type LookupPayload = z.infer<typeof LookupPayloadSchema>;

export const performLookup: WrappableTask = async (client, rawPayload) => {
  const payload = LookupPayloadSchema.parse(rawPayload);
  const { access_id, phone_number } = payload;

  // Update state fetching
  // Necessary as default values
  await client.query(
    `
    with client_id as (
        update lookup.accesses set state = 'fetching'
        where id = $1
        returning client_id
    )
    select set_config('client.id', ( select client_id::text from client_id ), false);`,
    [access_id]
  );

  const result = await lookup(phone_number);
  const { carrier_name, phone_type } = result;

  // Store lookup
  await client.query(
    `
      insert into lookup.lookups (phone_number, carrier_name, phone_type, raw_result)
      values ($1, $2, $3, $4);
    `,
    [
      phone_number,
      carrier_name,
      useUnknownPhoneTypeIfNotDefined(phone_type, carrier_name),
      result,
    ]
  );
};

function useUnknownPhoneTypeIfNotDefined(
  phoneType: string,
  carrierName: string
) {
  if (!VALID_PHONE_TYPES.includes(phoneType)) {
    if (!carrierName || carrierName === '') {
      return 'invalid';
    }

    return 'unknown';
  }

  return phoneType;
}
