import assembleNumbersClient from 'assemble-numbers-client';
import chunk from 'lodash/chunk';
import { Pool } from 'pg';

/* tslint:disable */

if (!process.env.SWITCHBOARD_API_KEY) {
  throw new Error('SWITCHBOARD_API_KEY envvar undefined');
}

const pool = new Pool({ connectionString: process.env.SPOKE_DATABASE_URL });
const numbersClient = new assembleNumbersClient({
  apiKey: process.env.SWITCHBOARD_API_KEY,
});

const summary = async () => {
  const { rows: result } = await pool.query(`
    select count(*), campaign_id, timezone
    from campaign_contact
    where exists (
      select 1
      from message
      where send_status = 'ERROR'
        and service_id = ''
        and created_at > now() - interval '2 days'
        and campaign_contact_id = campaign_contact.id
    )
    group by 2, 3;
  `);

  return result;
};

const BATCH_SIZE = 5000;
const CONCURRENCY = 10;

const resendMessage = async (
  id: number,
  text: string,
  contactNumber: string,
  profileId: string,
  contactZipCode: string
) => {
  try {
    const sent = await numbersClient.sms.sendMessage({
      contactZipCode,
      profileId,
      body: text,
      to: contactNumber,
    });

    const serviceId = sent.data.sendMessage.outboundMessage.id;

    await pool.query(
      'update message set send_status = $1, service_id = $2 where id = $3',
      ['SENT', serviceId, id]
    );
  } catch (ex) {
    console.log('Ex', ex);
    console.log(text);
  }
};

const rerun = async (timezone: string) => {
  const { rows: messages } = await pool.query(
    `
    select
      message.id,
      message.text,
      message.contact_number,
      messaging_service_stick.messaging_service_sid,
      campaign_contact.zip
    from message
    join campaign_contact on campaign_contact.id = message.campaign_contact_id
    join campaign on campaign_contact.campaign_id = campaign.id
    join messaging_service_stick on messaging_service_stick.cell = message.contact_number
      and messaging_service_stick.organization_id = campaign.organization_id
    where message.send_status = 'ERROR'
      and service_id = ''
      and message.created_at > now() - interval '2 days'
      and coalesce(campaign_contact.timezone, campaign.timezone) = $2
    order by campaign.id
    limit $1
  `,
    [BATCH_SIZE, timezone]
  );

  const countToSend = messages.length;
  const batches = chunk(messages, CONCURRENCY);

  let batchCount = 0;

  for (const batch of batches) {
    console.log(batchCount * CONCURRENCY);

    await Promise.all(
      batch.map((message) =>
        resendMessage(
          message.id,
          message.text,
          message.contact_number,
          message.messaging_service_sid,
          message.zip
        )
      )
    );

    batchCount++;
  }

  // for each
  // send each message using numbers-client
  // update service id and send status
};

rerun('America/New_York').then(summary).then(console.log);
