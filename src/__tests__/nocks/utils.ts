import { Body } from 'nock';
import { getBoundary, parse } from 'parse-multipart-data';
// tslint:disable-next-line: import-name
import qs from 'querystring';

type Headers = Record<string, string>;

export const parseMultipart = (
  headers: Headers,
  body: Body
): Record<string, any> => {
  const boundary = getBoundary(headers['content-type']);
  if (typeof body === 'string') {
    const parts = parse(Buffer.from(body, 'utf-8'), boundary);
    return parts.reduce(
      (acc, part) =>
        part.name
          ? {
              ...acc,
              [part.name]: part.data.toString('utf-8'),
            }
          : acc,
      {}
    );
  }
  return body;
};

export const parseUrlEncodedBody = (body: Body) => {
  return typeof body === 'string' ? qs.parse(body) : body;
};
