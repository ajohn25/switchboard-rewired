import { Service } from '../../lib/types';
import { TelcoMock } from './types';

import { InvalidServiceError } from '../../lib/errors';
import { BandwidthMock } from './bandwidth';
import { TelnyxMock } from './telnyx';
import { TwilioMock } from './twilio';

export const getMock = (service: Service): TelcoMock => {
  switch (service) {
    case Service.Bandwidth:
      return BandwidthMock;
    case Service.Telnyx:
      return TelnyxMock;
    case Service.Twilio:
      return TwilioMock;
    default:
      throw new InvalidServiceError(service);
  }
};
