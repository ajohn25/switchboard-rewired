import nock from 'nock';
import { TCR_BASE_URL } from '../../../lib/services/tcr';
import { MNO_METADATA_RESULT } from '../shared/constants';

export const nockGetMNOMetadata = () => {
  nock(TCR_BASE_URL)
    .get(new RegExp('.*/mnoMetadata'))
    .reply(200, (uri, requestBody) => {
      return MNO_METADATA_RESULT;
    });
};
