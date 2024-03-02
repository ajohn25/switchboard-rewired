import { OrderStatus } from '@bandwidth/numbers';
import faker from 'faker';
import nock from 'nock';
import xml2js from 'xml2js';

import { BANDWIDTH_API_URL } from './constants';

interface MockOrderOptions {
  accountId?: string;
  orderId?: string;
  status?: OrderStatus;
  campaignId?: string;
  phoneNumbers: string[];
}

const mockTnOptionsOrder = ({
  accountId = `${faker.random.number(10000)}`,
  orderId = faker.random.uuid(),
  campaignId = faker.random.uuid(),
  status = 'RECIEVED',
  phoneNumbers,
}: MockOrderOptions) => {
  const result = new xml2js.Builder().buildObject({
    TnOptionOrderResponse: {
      TnOptionOrder: {
        OrderCreateDate: new Date().toISOString(),
        AccountId: accountId,
        CreatedByUser: 'switchboardprod',
        OrderId: orderId,
        LastModifiedDate: new Date().toISOString(),
        ProcessingStatus: status,
        TnOptionGroups: {
          Sms: 'on',
          A2pSettings: {
            Action: 'asSpecified',
            CampaignId: campaignId,
            TelephoneNumbers: phoneNumbers.map((phoneNumber) => ({
              TelephoneNumber: phoneNumber.replace('+1', ''),
            })),
          },
        },
      },
    },
  });
  return result;
};

export const nockCreateTnOptionsOrder = () =>
  nock(BANDWIDTH_API_URL)
    .post(/\/api\/accounts\/[\d]*\/tnoptions/)
    .once()
    .reply(
      201,
      async (uri, body) => {
        const reqbody = await xml2js.parseStringPromise(body, {
          normalize: true,
          normalizeTags: true,
          explicitArray: false,
        });
        const {
          tnoptionorder: {
            tnoptiongroups: {
              tnoptiongroup: {
                a2psettings: { campaignid: campaignId },
                telephonenumbers,
              },
            },
          },
        } = reqbody;

        const numbersList = Array.isArray(telephonenumbers)
          ? telephonenumbers
          : [telephonenumbers];
        const phoneNumbers = numbersList.map(
          ({ telephonenumber }) => telephonenumber
        );
        return mockTnOptionsOrder({ campaignId, phoneNumbers });
      },
      { 'Content-Type': 'application/xml' }
    );
