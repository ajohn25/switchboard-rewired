import { nockCreateMessage } from './messages';
import { nockTwilioNumberAvailability } from './number-availability';
import {
  nockDeleteNumber,
  nockGetPhoneNumberId,
  nockPurchaseNumber,
} from './phone-numbers';
import { nockSetMessagingProfile } from './set-messaging-profile';

// tslint:disable-next-line: variable-name
export const TwilioNock = {
  createMessage: nockCreateMessage,
  deleteNumber: nockDeleteNumber,
  getNumberAvailability: nockTwilioNumberAvailability,
  getPhoneNumberId: nockGetPhoneNumberId,
  purchaseNumber: nockPurchaseNumber,
  setMessagingProfile: nockSetMessagingProfile,
};
