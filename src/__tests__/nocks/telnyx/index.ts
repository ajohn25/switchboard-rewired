import { nockGetMNOMetadata } from './10dlc-mno-metadata';
import { nockCreatePhoneNumberCampaign } from './10dlc-phone-number-camapign';
import { nockGetAvailableNumbers } from './available-numbers';
import { nockCreateMessage } from './messages';
import { nockCreateOrder, nockGetOrder } from './number-orders';
import { nockDeleteNumber, nockGetNumbers } from './phone-numbers';
import { nockSetMessagingProfile } from './set-messaging-profile';

// tslint:disable-next-line: variable-name
export const TelnyxNock = {
  createMessage: nockCreateMessage,
  createNumberOrder: nockCreateOrder,
  createPhoneNumberCampaign: nockCreatePhoneNumberCampaign,
  getMNOMetadata: nockGetMNOMetadata,
  deletePhoneNumber: nockDeleteNumber,
  getAvailableNumbers: nockGetAvailableNumbers,
  getNumberOrder: nockGetOrder,
  getPhoneNumbers: nockGetNumbers,
  setMessagingProfile: nockSetMessagingProfile,
};
