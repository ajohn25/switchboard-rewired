import { db, sql } from '../db';
import { IncomingMessage } from '../lib/types';

export const presistIncomingMessage = async (
  message: IncomingMessage
): Promise<string> => {
  const {
    from,
    to,
    body,
    receivedAt,
    service,
    serviceId,
    numSegments,
    numMedia,
    mediaUrls,
    extra,
    validated,
  } = message;

  const mediaArray = sql.array(mediaUrls || [], 'text');
  const extraJson = sql.json(extra);

  const [{ id }] = await db(sql`
    insert into sms.inbound_messages (
      from_number, to_number, body, received_at, service, service_id,
      num_segments, num_media, media_urls, extra, validated
    )
    values (
      ${from}, ${to}, ${body}, ${receivedAt}, ${service}, ${serviceId},
      ${numSegments}, ${numMedia}, ${mediaArray}, ${extraJson}, ${validated}
    )
    returning id
  `);

  return id;
};
