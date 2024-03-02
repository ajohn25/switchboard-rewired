/* tslint:disable */
import twilio from 'twilio';
import { IncomingMessage } from '../src/lib/types';
import { db, sql } from '../src/db';
import { presistIncomingMessage } from '../src/lib/inbound';

/**
 * This script was built to recover dropped replies from the Cloudflare outage on 07-17
 * It should be run per account or Telnyx exported MDR
 */

const OUTAGE_START_UTC = new Date('2020-07-17T21:11:00.000Z');
const OUTAGE_END_UTC = new Date('2020-07-17T21:19:00.000Z');

const main = async () => {
  const instance = twilio(process.env.ACCOUNT_SID, process.env.AUTH_TOKEN);

  instance.messages.each(
    {
      dateSentAfter: OUTAGE_START_UTC,
      dateSentBefore: OUTAGE_END_UTC,
    },
    async (message) => {
      if (message.direction === 'inbound') {
        const toInsert: IncomingMessage = {
          from: message.from,
          to: message.to,
          body: message.body,
          serviceId: message.sid,
          service: 'twilio',
          numSegments: parseInt(message.numSegments, 10),
          numMedia: parseInt(message.numMedia, 10),
          receivedAt: message.dateCreated.toISOString(),
          mediaUrls: [],
          validated: true,
          extra: null,
        };

        const existingMessages = await db(
          sql`select 1 from sms.inbound_messages where service_id = ${toInsert.serviceId}`
        );

        if (existingMessages.length > 0) {
          console.log(`${toInsert.serviceId} already exists`);
        } else {
          console.log(`Inserting ${toInsert.serviceId}`);
          console.log(toInsert);
          await presistIncomingMessage(toInsert);
        }
      }
    }
  );
};

main().then(console.log).catch(console.error);
