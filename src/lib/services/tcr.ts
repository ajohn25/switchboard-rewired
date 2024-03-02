import superagent from 'superagent';

import { crypt } from '../crypt';
import { SendingAccount, TcrCredentials } from '../types';
import {
  GetMnoMetadataOptions,
  GetMnoMetadataPayload,
  SwitchboardClient,
} from './service';

export const TCR_BASE_URL = 'https://csp-api.campaignregistry.com/v2';

export class TcrService extends SwitchboardClient {
  protected credentials: TcrCredentials;

  constructor(sendingAccount: SendingAccount) {
    super(sendingAccount);

    const { tcr_credentials } = sendingAccount;
    if (tcr_credentials === null) {
      throw new Error(
        `Undefined tcr credentials for sending account ${sendingAccount.sending_account_id}`
      );
    }
    this.credentials = tcr_credentials;
  }

  public async getMnoMetadata({
    campaignId,
  }: GetMnoMetadataOptions): Promise<GetMnoMetadataPayload> {
    const { api_key, secret } = this.getApiCredentials();
    const response = await superagent
      .get(`${TCR_BASE_URL}/campaign/${campaignId}/mnoMetadata`)
      .auth(api_key, secret);

    return response.body;
  }

  protected getApiCredentials() {
    const { api_key, encrypted_secret } = this.credentials;
    const secret = crypt.decrypt(encrypted_secret);
    return { api_key, secret };
  }
}
