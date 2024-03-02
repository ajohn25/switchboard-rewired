import faker from 'faker';
import nock from 'nock';

type NockGenericSpokeReqOptions = {
  url: string;
  callback?: (headers: Record<string, any>) => void;
} & ({ code: '200' } | { code: '500' });

const nockGenericSpokeReq = (options: NockGenericSpokeReqOptions) =>
  nock(options.url)
    .post('/')
    .reply(function (url, requestBody) {
      if (options.callback) {
        options.callback(this.req.headers);
      }
      if (options.code === '200') {
        return [200, null];
      }
      if (options.code === '500') {
        return [500, faker.internet.password()];
      }
    });

// tslint:disable-next-line: variable-name
export const SpokeNock = {
  genericRequest: nockGenericSpokeReq,
};
