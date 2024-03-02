import { Pool } from 'pg';
import telnyx from 'telnyx';
import config from '../src/config';
import { crypt } from '../src/lib/crypt';
import { SendingAccount, TelnyxCredentials } from '../src/lib/types';
import { logger } from '../src/logger';

/* tslint:disable */

const NUMBER_COUNT = 5;
const TELNYX_ORDER_POLLING_INTERVAL_MS = 1000;

export interface PurchaseNumberPayload extends SendingAccount {
  area_code: string;
  id: string;
  sending_account_id: string;
  sending_location_id: string;
}

const purchaseNumberTelnyx = async (
  credentials: TelnyxCredentials,
  areaCode: string
) => {
  const { encrypted_api_key } = credentials;
  const apiKey = crypt.decrypt(encrypted_api_key);
  const telnyxClient = telnyx(apiKey);
  const {
    data: matchingNumbers,
  } = await telnyxClient.availablePhoneNumbers.list({
    filter: {
      country_code: 'US',
      exclude_regulatory_requirements: true,
      features: ['voice'],
      limit: NUMBER_COUNT,
      national_destination_code: areaCode,
    },
  });

  while (matchingNumbers.length > 0) {
    const { phone_number } = matchingNumbers.shift();
    try {
      const { data: order } = await telnyxClient.numberOrders.create({
        // messaging_profile_id,
        phone_numbers: [{ phone_number }],
      });
      const orderUuid = order.id;
      console.log(`${orderUuid}: ${phone_number}`);
      let orderStatus = order.status;
      while (orderStatus === 'pending') {
        await new Promise(resolve =>
          setTimeout(resolve, TELNYX_ORDER_POLLING_INTERVAL_MS)
        );
        const {
          data: { status },
        } = await telnyxClient.numberOrders.retrieve(orderUuid);
        orderStatus = status;
      }

      if (orderStatus !== 'success') {
        logger.error(`Telnyx order ${orderUuid} failed!`);
        return undefined;
      }

      return phone_number;
    } catch (exc) {
      // Likely someone else beat us to purchasing this phone number. Try the next matching one.
      logger.error('Error purchasing Telnyx number', exc);
      continue;
    }
  }

  return undefined;
};

/**
 * Purchase and configure a number meeting requirements specified in the payload.
 * @param client PoolClient
 * @param payload Phone number request (including sending profile)
 */

const purchaseTelnyxVoiceNumbers = async (
  sendingAccountId: string,
  areaCode: string,
  count: number
): Promise<void> => {
  const pool = new Pool({ connectionString: config.databaseUrl });
  const {
    rows: [row],
  } = await pool.query(
    'select row_to_json(telnyx_credentials) from sms.sending_accounts where id = $1',
    [sendingAccountId]
  );
  const credentials = row.row_to_json;

  for (const _run of new Array(count).fill(null)) {
    const result = await purchaseNumberTelnyx(credentials, areaCode);
  }
};

purchaseTelnyxVoiceNumbers('c63f1bf0-ec57-11e9-b8d9-ef28ac8d64da', '207', 9)
  .then(console.log)
  .catch(console.error);

// fb70fdaa-2a86-4504-9fed-e70315b3c917: +12072263737
// 95571acc-c0d6-475f-a5d3-e0688771f80f: +12072414112
// 334f51c9-658b-4220-9a6a-5d595c4cfa25: +12072414162
// e5442ea7-0cb1-4d4b-aff6-8bc255620c58: +12072496285
// 3fdc66e0-30a2-49f7-85e7-9c4fd51e696a: +12072496585
// efbc20c0-dd7e-465c-86fa-0019aa1de6dc: +12072414192
// ee443a3e-ab0e-4628-81bf-3ca27bfdb8a0: +12072414209
// be1da731-df0d-4954-b5ba-a74cd7fa7437: +12072419506
// 17146e3b-8a3c-46c6-944a-33f4878393e2: +12072419810
// 7f6b4620-0ebf-407c-9211-e12082098790: +12072500071
// 8847668e-745a-46f6-a210-725ad90628d9: +12072610021
// bd811600-39e6-466e-ac6e-9e4483bbb2a0: +12072610177
// 0f707acf-8303-47be-ad29-778e270f9a16: +12072610401
// 8bbdef8e-b95d-4922-b912-15056675c914: +12072610444
// d16028df-2f36-465b-b437-b16581da8c86: +12072610516
// 08615f93-5a21-49c9-9b2d-f9adf8a48c6d: +12072610522
// a7956d7a-78c4-417f-922f-df93a5889118: +12072610528
// 2f4a7877-39b0-41be-a322-56cf07c0905b: +12072610534
// 6664135f-c4c3-4ee3-8e24-d76f17c372e7: +12072610540
// 007af5e3-7228-4712-8bbf-24f9e1f2de71: +12072610546
// 4a0884e6-fb93-4fdf-a09a-ab3e60f36b9c: +12072610549
// 3e580262-cdf3-401a-b885-2c1fc0bd84c0: +12072610552
// b202ac4a-9114-40d0-abb8-beeb96697438: +12072610572
// 3739181d-0f01-4719-848d-93ae01fd65e7: +12072610664
// 15381a8d-ae9f-478c-a2e0-924b37e7ac7c: +12072610688
// f3b79087-661f-430c-a11b-9472e706cf78: +12072610696
// 126034cc-1e0c-4bce-9a61-c5ccd02e52f4: +12072610774
// 76c24c45-50ee-4300-b773-4e0da9a3a8cf: +12072610779
// e5a6f692-92e2-4183-96ae-77f536d242ef: +12072610789
// c7693d67-92cc-4801-80b6-7433023cb09a: +12072610838
// 1b164794-9e2b-401b-a190-fdab28bdb0a4: +12072747595
// cb33773f-1101-41a4-b37a-6b4d30030f92: +12072747709
// 0838bb3c-ad8a-4566-ac44-23cdf9082965: +12072747801
// 754df3b4-2c23-476e-83f8-bcd998579936: +12072747854
// 1623f7b1-96a0-4213-8371-486225138b83: +12072747972
// 889cfd2d-1cfb-4c02-a335-1f7c195d90fd: +12072921188
// 0b6eb5f2-e8d4-4792-80a0-781a7aff989a: +12072921201
// eadd95c3-f011-4cb9-84ee-af81c7335465: +12072921358
// 63617ca1-b6ce-41f3-b631-adeb781da4e9: +12072921403
// e3a2b2b2-b8fa-4d1d-9d3e-161535ce20eb: +12072921666
// c9caaf2a-a244-4560-b11a-5fa3ec48872f: +12072921675
// ef65a467-8684-4802-a658-aa258aa31150: +12072921679
