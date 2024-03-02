import {
  PhoneNumberFormat as PNF,
  PhoneNumberUtil,
} from 'google-libphonenumber';
import { PoolClient } from 'pg';
import { SuperAgentRequest } from 'superagent';

const phoneUtil = PhoneNumberUtil.getInstance();

export function normalize(rawNumber: string) {
  try {
    const phoneNumber = phoneUtil.parseAndKeepRawInput(rawNumber, 'US');
    return phoneUtil.format(phoneNumber, PNF.E164) as string;
  } catch (ex) {
    return 'invalid';
  }
}

// 302 responses to POSTs are usually converted to GETs
// https://stackoverflow.com/a/55008140
type MakeRequest = (url: string) => SuperAgentRequest;
export const requestWith302Override = async (
  initialUrl: string,
  makeRequest: MakeRequest
) => {
  const response = await makeRequest(initialUrl)
    .redirects(0)
    .catch((err: any) => {
      if (err.status === 302 && err.response) {
        const { location } = err.response.headers;
        return makeRequest(location);
      }
      throw err;
    });
  return response;
};

export const sleep = async (ms: number) =>
  new Promise<void>((resolve) => {
    setTimeout(() => resolve(), ms);
  });

export const doesLivePhoneNumberExist = async (
  client: PoolClient,
  phoneNumber: string
) => {
  const liveNumberExists = await client
    .query<{ live_number_exists: boolean }>(
      `
        select exists (
          select 1
          from sms.all_phone_numbers
          where
            phone_number = $1
            and released_at is null
        ) as live_number_exists;
      `,
      [phoneNumber]
    )
    .then(({ rows: [{ live_number_exists }] }) => live_number_exists);
  return liveNumberExists;
};

export const nowAsDate = () => {
  const d = new Date();
  return d;
};

export const delay = async (ms: number) =>
  new Promise((resolve) => setTimeout(resolve, ms));
