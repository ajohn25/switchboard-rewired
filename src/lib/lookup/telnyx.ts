import config from '../../config';
const { telnyxApiKey } = config;

import superagent from 'superagent';

export default { lookup };

async function lookup(phoneNumber: string) {
  const url = `https://api.telnyx.com/v2/number_lookup/${phoneNumber}`;

  try {
    const result = await superagent
      .get(url)
      .set('Authorization', `Bearer ${telnyxApiKey}`)
      .set('Accept', 'application/json')
      .query({ format: 'json' });

    const {
      ported_status,
      ported_date,
      ocn,
      line_type,
      spid,
      spid_carrier_name,
    } = result.body.data.portability;

    // 2024-01-24 Telnyx v2 API refers to landlines as "fixed line"
    // Switchboard refers to this type of number as "landline"
    const phoneType = line_type === 'fixed line' ? 'landline' : line_type;

    return {
      ocn,
      ported_date,
      ported_status,
      spid,
      carrier_name: spid_carrier_name,
      number: phoneNumber,
      phone_type: phoneType,
    };
  } catch (ex) {
    return {
      number: phoneNumber,
      phone_type: 'invalid',
    };
  }
}
