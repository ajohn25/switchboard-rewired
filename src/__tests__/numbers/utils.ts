import faker from 'faker';
import cloneDeep from 'lodash/cloneDeep';
import { PoolClient } from 'pg';

import { db, PoolOrPoolClient, sql } from '../../db';
import {
  IncomingMessage,
  TelnyxReplyRequestBody,
  TwilioReplyRequestBody,
} from '../../lib/types';

export const destroySendingAccount = async (
  sendingAccountId: string
): Promise<void> => {
  await db(
    sql`delete from sms.inbound_messages where sending_location_id in ( select id from sms.sending_locations where profile_id in ( select id from sms.profiles where sending_account_id = ${sendingAccountId} ) )`
  );

  await db(sql`delete from sms.delivery_reports`);

  await db(
    sql`delete from sms.outbound_messages where profile_id in ( select id from sms.profiles where sending_account_id = ${sendingAccountId} )`
  );

  await db(
    sql`delete from sms.all_phone_numbers where sending_location_id in ( select id from sms.sending_locations where profile_id in ( select id from sms.profiles where sending_account_id = ${sendingAccountId} ) )`
  );

  await db(
    sql`delete from sms.sending_locations where profile_id in ( select id from sms.profiles where sending_account_id = ${sendingAccountId} )`
  );

  await db(
    sql`delete from sms.profiles where sending_account_id = ${sendingAccountId}`
  );

  await db(
    sql`delete from sms.sending_accounts where id = ${sendingAccountId}`
  );
};

export const fetchAndDestroyMessage = async (messageId: string) => {
  const [row] = await db(
    sql`select * from sms.inbound_messages where id = ${messageId}`
  );

  const message: IncomingMessage = {
    body: row.body,
    extra: row.extra,
    from: row.from_number,
    mediaUrls: row.media_urls,
    numMedia: row.numMedia,
    numSegments: row.numSegments,
    receivedAt: row.received_at,
    service: row.service,
    serviceId: row.service_id,
    to: row.to_number,
    validated: row.validated,
  };

  await db(sql`delete from sms.inbound_messages where id = ${messageId}`);

  return message;
};

export const setClientIdConfig = async (
  client: PoolClient,
  clientId: string
) => {
  await client.query(`select set_config('client.id', $1, false)`, [clientId]);
};

export interface GenericJobPayload {
  [key: string]: any;
}
export interface Job<P = GenericJobPayload> {
  queue_name: string;
  payload: P;
}

export const findJobs = async <P = GenericJobPayload>(
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  value: string
) => {
  const jobs = await findGraphileWorkerJobs(client, queueName, key, value);
  return jobs;
};

export const findJob = async <P = GenericJobPayload>(
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  value: string
) => {
  const jobs = await findJobs<P>(client, queueName, key, value);
  return jobs[0];
};

export const findGraphileWorkerJobs = async (
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  value: string
) => {
  const query = sql`
    select jobs.*, tasks.identifier as task_identifier
    from graphile_worker.jobs
    join graphile_worker.tasks on jobs.task_id = tasks.id
    where
      tasks.identifier = ${queueName}
      and payload::jsonb->>${key} = ${value}
  `;

  const { rows } = await client.query<any>(query.sql, [...query.values]);
  return rows;
};

export const findGraphileWorkerJob = async (
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  value: string
) => {
  const jobs = await findGraphileWorkerJobs(client, queueName, key, value);
  return jobs[0];
};

export const countJobs = async (
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  value: string
) => {
  const query = sql`
    select 1
    from graphile_worker.jobs
    join graphile_worker.tasks on jobs.task_id = tasks.id
    where
      tasks.identifier = ${queueName}
      and payload::jsonb->>${key} = ${value}
  `;

  const { rowCount } = await client.query(query.sql, [...query.values]);
  return rowCount;
};

export const findJobWithArrayIncludes = async (
  client: PoolOrPoolClient,
  queueName: string,
  key: string,
  valueMustInclude: string
) => {
  const query = sql`
    select jobs.*, tasks.identifier as task_identifier
    from graphile_worker.jobs
    join graphile_worker.tasks on jobs.task_id = tasks.id
    where
      tasks.identifier = ${queueName}
      and (payload::jsonb->>${key})::jsonb ? ${valueMustInclude}
  `;

  const { rows } = await client.query<any>(query.sql, [...query.values]);
  return rows[0];
};

export const fakeNumber = (areaCode: string = '####') =>
  faker.phone.phoneNumber(`+1${areaCode}#######`);

export const generateMockTelnyxMessageToNumber = (toNumber: string) => {
  const mockMessage: {
    body: TelnyxReplyRequestBody;
    headers: { [key: string]: string };
  } = cloneDeep(mockTelnyxMessage);

  mockMessage.body.data.payload.to = toNumber;
  return mockMessage;
};

export const mockTelnyxMessage: {
  body: TelnyxReplyRequestBody;
  headers: { [key: string]: string };
} = {
  body: {
    data: {
      event_type: 'message.received',
      id: '031f1801-48b8-4e98-8471-61f772a98678',
      occurred_at: '2019-09-19T16:22:38.444+00:00',
      payload: {
        completed_at: null,
        cost: null,
        direction: 'inbound',
        encoding: 'UCS-2',
        errors: [],
        from: {
          carrier: 'Verizon Wireless',
          line_type: 'long_code',
          phone_number: '+12147010869',
          status: 'webhook_delivered',
        },
        id: '3ef298fb-f014-4705-bb00-d724a2e55d59',
        media: [
          {
            content_type: 'image/jpeg',
            hash_sha256:
              '7906abe9e4aaa9e0d941392a8b1091946f0ceca44624ad5d629dbe6fea3ce819',
            size: 1003429,
            url: 'https://tlnx-mms-media.s3.amazonaws.com/mms/d4e96d57367a6e68203b511d5c459210/7906abe9e4aaa9e0d941392a8b1091946f0ceca44624ad5d629dbe6fea3ce819.jpeg',
          },
        ],
        messaging_profile_id: 'ca8ccae8-befd-4f5b-97dd-1b3209cfb02c',
        organization_id: 'e846690a-cf75-4d26-995e-f2bcce5cdb0f',
        parts: 1,
        received_at: '2019-09-19T16:22:38.189+00:00',
        record_type: 'message',
        sent_at: null,
        text: "\nhere's a picture! ",
        to: '+19175124579',
        type: 'MMS',
        valid_until: null,
        webhook_failover_url: null,
        webhook_url: 'https://en35i6u4miems.x.pipedream.net',
      },
      record_type: 'event',
    },
    meta: {
      attempt: 1,
      delivered_to: 'https://en35i6u4miems.x.pipedream.net',
    },
  },
  headers: {
    'Content-Type': 'application/json',
    'Telnyx-Signature-Ed25519':
      'vIpBkjRdrNXvShUNPXKDvUzNeZoPrOKxV329ngiix+M6qYZqfJ3uiswNqHSKRKG1v+1DKTXPcy7rxOs26//DDw==',
    'Telnyx-Timestamp': '1568910158',
    'user-agent': 'telnyx-webhooks',
  },
};

/*
 * done with request bin: en35i6u4miems.x.pipedream.net
 */

export const mockTwilioMessage: {
  body: TwilioReplyRequestBody;
  headers: { [key: string]: string };
} = {
  body: {
    AccountSid: 'AC0c815458691fc4700e92c66a0c8f01b4',
    ApiVersion: '2010-04-01',
    Body: 'hello twilio ',
    From: '+12147010869',
    FromCity: 'GRAND PRAIRIE',
    FromCountry: 'US',
    FromState: 'TX',
    FromZip: '75052',
    MessageSid: 'SM8a6693da7f6e2a6da1a94fd04b0e7d5b',
    MessagingServiceSid: 'MG794ce834ddc2eb5f1f45ee4f1d28092a',
    NumMedia: '0',
    NumSegments: '1',
    SmsMessageSid: 'SM8a6693da7f6e2a6da1a94fd04b0e7d5b',
    SmsSid: 'SM8a6693da7f6e2a6da1a94fd04b0e7d5b',
    SmsStatus: 'received',
    To: '+19177466488',
    ToCity: 'BROOKLYN',
    ToCountry: 'US',
    ToState: 'NY',
    ToZip: '11222',
  },
  headers: {
    'Content-Type': 'application/x-www-form-urlencoded',
    'I-Twilio-Idempotency-Token': '47349914-b670-4d15-8113-45da7181c427',
    'User-Agent': 'TwilioProxy/1.1',
    'X-Twilio-Signature': 'XEWN3kdbAxM/zXgPVwMDuyz1npQ=',
  },
};
