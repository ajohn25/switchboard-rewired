import { OrderStatus } from '@bandwidth/numbers';
import faker from 'faker';
import nock from 'nock';
import xml2js from 'xml2js';

import { BANDWIDTH_API_URL } from './constants';

interface MockOrderOptions {
  orderId?: string;
  status?: OrderStatus;
  siteId?: string;
  phoneNumbers: string[];
}

const mockBandwidthOrder = ({
  orderId = faker.random.uuid(),
  siteId = `${faker.random.number(10000)}`,
  status = 'RECIEVED',
  phoneNumbers,
}: MockOrderOptions) => {
  const result = new xml2js.Builder().buildObject({
    OrderResponse: {
      OrderStatus: status,
      Order: {
        OrderCreateDate: new Date().toISOString(),
        BackOrderRequested: false.valueOf,
        id: orderId,
        SiteId: siteId,
        PartialAllowed: true,
        ExistingTelephoneNumberOrderType: {
          TelephoneNumberList: phoneNumbers.map((phoneNumber) => ({
            TelephoneNumber: phoneNumber,
          })),
        },
      },
    },
  });
  return result;
};

export const nockCreateOrder = () =>
  nock(BANDWIDTH_API_URL)
    .post(/\/api\/accounts\/[\d]*\/orders/)
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
          order: {
            siteid: siteId,
            existingtelephonenumberordertype: { telephonenumberlist },
          },
        } = reqbody;
        const numbersList = Array.isArray(telephonenumberlist)
          ? telephonenumberlist
          : [telephonenumberlist];
        const phoneNumbers = numbersList.map(
          ({ telephoneNumber }) => telephoneNumber
        );
        return mockBandwidthOrder({ siteId, phoneNumbers });
      },
      { 'Content-Type': 'application/xml' }
    );

interface GetOrderOptions {
  phoneNumbers: string[];
  status: OrderStatus;
}

const getOrderRegEx = /\/api\/accounts\/[\d]*\/orders\/(.*)$/;
export const nockGetOrder = (options: GetOrderOptions) =>
  nock(BANDWIDTH_API_URL)
    .get(getOrderRegEx)
    .once()
    .reply(
      201,
      async (uri, body) => {
        const { status, phoneNumbers } = options;
        const orderId = uri.match(getOrderRegEx)![1];
        return mockBandwidthOrder({ orderId, phoneNumbers, status });
      },
      { 'Content-Type': 'application/xml' }
    );
