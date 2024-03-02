import faker from 'faker';
import nock from 'nock';

import { TelnyxOrderResponse } from '../../../lib/types';
import { TELNYX_V2_API_URL } from './constants';

interface MockOrderOptions {
  id?: string;
  status?: 'success' | 'pending';
  phoneNumbers: string[];
  serviceProfileId: string | null;
}

const mockTelnyxOrder = ({
  id,
  status,
  serviceProfileId,
  phoneNumbers,
}: MockOrderOptions): TelnyxOrderResponse => ({
  data: {
    connection_id: '442191469269222625',
    created_at: '2018-01-01T00:00:00.000000Z',
    customer_reference: 'MY REF 001',
    id: id ?? faker.random.uuid(),
    messaging_profile_id: serviceProfileId,
    phone_numbers: phoneNumbers.map((phoneNumber) => ({
      id: '123cvgbh-fvgbhn-fvgbh-vgbh',
      phone_number: phoneNumber,
      record_type: 'number_order_phone_number',
      regulatory_requirements: [],
      requirements_met: true,
      status: 'success',
    })),
    phone_numbers_count: 1,
    record_type: 'number_order',
    requirements_met: true,
    status: status ?? 'pending',
    updated_at: '2018-01-01T00:00:00.000000Z',
  },
});

interface CreateOrderOptions {
  serviceProfileId: string | null;
}

export const nockCreateOrder = (options: CreateOrderOptions) =>
  nock(TELNYX_V2_API_URL)
    .post('/number_orders')
    .reply(
      200,
      (uri, body: Pick<TelnyxOrderResponse['data'], 'phone_numbers'>) => {
        const phoneNumbers: string[] = body.phone_numbers.map(
          ({ phone_number }) => phone_number
        );
        const { serviceProfileId } = options;
        return mockTelnyxOrder({
          phoneNumbers,
          serviceProfileId,
        });
      }
    );

interface GetOrderOptions {
  phoneNumbers: string[];
  serviceProfileId: string;
  status: 'success' | 'pending';
}

export const nockGetOrder = (options: GetOrderOptions) =>
  nock(TELNYX_V2_API_URL)
    .get(new RegExp('/number_orders/.*'))
    .reply(200, (uri, body) => {
      const orderId = uri.match(new RegExp('/number_orders/(.*)'))![1];
      const { phoneNumbers, serviceProfileId, status } = options;
      return mockTelnyxOrder({
        phoneNumbers,
        serviceProfileId,
        status,
        id: orderId,
      });
    });
