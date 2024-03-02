import nock from 'nock';
import { MNO_METADATA_RESULT } from '../shared/constants';
import { TELNYX_10DLC_API_BASE } from './constants';

export const nockGetMNOMetadata = () => {
  nock(TELNYX_10DLC_API_BASE)
    .get(new RegExp('.*/mnoMetadata'))
    .reply(200, (uri, requestBody) => {
      return MNO_METADATA_RESULT;
    });
};
