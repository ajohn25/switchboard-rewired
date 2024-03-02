import crypto from 'crypto';
import superagent from 'superagent';
import { z } from 'zod';

import { crypt } from '../lib/crypt';
import {
  DeliveryReportEvent,
  DeliveryReportEventSchema,
  DeliveryReportExtra,
  DeliveryReportExtraSchema,
  WrappableTask,
} from '../lib/types';
import { requestWith302Override } from '../lib/utils';
import { errToObj, logger } from '../logger';
import { ProfileSendingAccountPayloadSchema } from './schema-validation';

export const FORWARD_DELIVERY_REPORT_IDENTIFIER = 'forward-delivery-report';

// tslint:disable-next-line variable-name
export const ForwardDeliveryReportPayloadSchema =
  ProfileSendingAccountPayloadSchema.pick({
    encrypted_client_access_token: true,
    profile_id: true,
    message_status_webhook_url: true,
  }).extend({
    message_id: z.string(),
    event_type: DeliveryReportEventSchema,
    generated_at: z.string(),
    error_codes: z.array(z.string()).nullable(),
    extra: DeliveryReportExtraSchema.nullable(), // Can be null for `delivery_failed` event
  });

export type ForwardDeliveryReportPayload = z.infer<
  typeof ForwardDeliveryReportPayloadSchema
>;

const constructSignature = (payload: ForwardDeliveryReportPayload) => {
  const clientAccessToken = crypt.decrypt(
    payload.encrypted_client_access_token
  );

  return crypto
    .createHmac('sha1', clientAccessToken)
    .update(`${payload.message_id}|${payload.event_type}`)
    .digest('hex');
};

interface ForwardedDeliveryReport {
  messageId: string;
  eventType: DeliveryReportEvent;
  generatedAt: string;
  errorCodes: string[] | null;
  profileId: string;
  extra?: DeliveryReportExtra;
}

export const forwardDeliveryReport: WrappableTask = async (
  _client,
  rawPayload
) => {
  const payload = ForwardDeliveryReportPayloadSchema.parse(rawPayload);

  const signature = constructSignature(payload);

  const toForward: ForwardedDeliveryReport = {
    errorCodes: payload.error_codes,
    eventType: payload.event_type,
    generatedAt: payload.generated_at,
    messageId: payload.message_id,
    profileId: payload.profile_id,
  };

  if (payload.extra) {
    toForward.extra = payload.extra;
  }
  const headers = {
    'x-assemble-signature': signature,
  };

  try {
    await requestWith302Override(
      payload.message_status_webhook_url,
      (url: string) => superagent.post(url).set(headers).send(toForward)
    );
  } catch (err) {
    logger.error('Error forwarding delivery report', {
      ...errToObj(err),
      deliveryReport: toForward,
    });

    throw err;
  }
};
