import { nockCreateTnOptionsOrder } from './associate-10dlc-campaign';
import { nockGetAvailableNumbers } from './available-numbers';
import { nockCreateMessage } from './messages';
import { nockCreateOrder, nockGetOrder } from './phone-number-orders';
import { nockDisconnectNumber } from './phone-numbers';

// tslint:disable-next-line: variable-name
export const BandwidthNock = {
  createTnOptionsOrder: nockCreateTnOptionsOrder,
  createMessage: nockCreateMessage,
  createNumberOrder: nockCreateOrder,
  disconnectPhoneNumber: nockDisconnectNumber,
  getAvailableNumbers: nockGetAvailableNumbers,
  getNumberOrder: nockGetOrder,
};
