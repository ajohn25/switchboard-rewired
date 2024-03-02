import config from '../../config';
import { InvalidServiceError } from '../errors';
import { SendingAccount, Service } from '../types';
import { BandwidthDryRunService, BandwidthService } from './bandwidth';
import { SwitchboardClient } from './service';
import { TcrService } from './tcr';
import { TelnyxService } from './telnyx';
import { TwilioService } from './twilio';

export const getTelcoClient = (
  sendingAccount: SendingAccount
): SwitchboardClient => {
  if (config.dryRunMode) return new BandwidthDryRunService(sendingAccount);

  switch (sendingAccount.service) {
    case Service.Telnyx:
      return new TelnyxService(sendingAccount);
    case Service.Twilio:
      return new TwilioService(sendingAccount);
    case Service.Bandwidth:
      return new BandwidthService(sendingAccount);
    case Service.BandwidthDryRun:
      return new BandwidthDryRunService(sendingAccount);
    case Service.Tcr:
      return new TcrService(sendingAccount);
    default:
      throw new InvalidServiceError(sendingAccount.service);
  }
};
