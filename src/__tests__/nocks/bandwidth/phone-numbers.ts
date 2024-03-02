import { OrderStatus } from '@bandwidth/numbers';
import faker from 'faker';
import nock from 'nock';
import xml2js from 'xml2js';

import { BANDWIDTH_API_URL } from './constants';

interface CreateDisconnectOrderOptions {
  id?: string;
  phoneNumbers: string[];
  orderStatus: OrderStatus;
}
const mockCreateDisconnectOrder = (options: CreateDisconnectOrderOptions) => {
  const result = new xml2js.Builder().buildObject({
    DisconnectTelephoneNumberOrderResponse: {
      orderRequest: {
        OrderCreateDate: new Date().toISOString(),
        id: faker.random.uuid(),
        DisconnectTelephoneNumberOrderType: {
          TelephoneNumberList: options.phoneNumbers.map((phoneNumber) => ({
            TelephoneNumber: phoneNumber,
          })),
        },
      },
      OrderStatus: options.orderStatus,
    },
  });
  return result;
};

type DeleteNumberResponse = 201;
interface NockDisconnectNumberOptions {
  orderStatus?: OrderStatus;
  responseCode?: DeleteNumberResponse;
}
export const nockDisconnectNumber = ({
  orderStatus = 'RECIEVED',
  responseCode = 201,
}: NockDisconnectNumberOptions) =>
  nock(BANDWIDTH_API_URL)
    .post(/\/api\/accounts\/[\d]*\/disconnects/)
    .reply(responseCode, async (uri, body) => {
      const reqbody = await xml2js.parseStringPromise(body, {
        normalize: true,
        normalizeTags: true,
        explicitArray: false,
      });
      const {
        disconnecttelephonenumberorder: {
          name,
          disconnecttelephonenumberordertype: { telephonenumberlist },
        },
      } = reqbody;
      const phoneNumberList = Array.isArray(telephonenumberlist)
        ? telephonenumberlist
        : [telephonenumberlist];
      const phoneNumbers = phoneNumberList.map(
        ({ telephonenumber }) => telephonenumber
      );
      return mockCreateDisconnectOrder({ orderStatus, phoneNumbers });
    });
