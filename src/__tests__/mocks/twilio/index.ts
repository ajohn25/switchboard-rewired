import { TelcoMock } from '../types';
import { mockTwilioMessageDelivered } from './messages';

// tslint:disable-next-line: variable-name
export const TwilioMock: TelcoMock = {
  mockMessageDelivered: mockTwilioMessageDelivered,
};

export default TwilioMock;
