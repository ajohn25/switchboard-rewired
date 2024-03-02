import { TelcoMock } from '../types';
import { mockBandwidthMessageDelivered } from './messages';

// tslint:disable-next-line: variable-name
export const BandwidthMock: TelcoMock = {
  mockMessageDelivered: mockBandwidthMessageDelivered,
};

export default BandwidthMock;
