import { TelcoMock } from '../types';
import { mockTelnyxMessageDelivered } from './messages';

// tslint:disable-next-line: variable-name
export const TelnyxMock: TelcoMock = {
  mockMessageDelivered: mockTelnyxMessageDelivered,
};

export default TelnyxMock;
