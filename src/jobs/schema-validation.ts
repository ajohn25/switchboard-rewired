import { z } from 'zod';

import { Service } from '../lib/types';

// tslint:disable-next-line variable-name
export const GraphileCronItemPayloadSchema = z
  .object({
    _cron: z
      .object({
        ts: z.string().datetime({ offset: true }),
        backfilled: z.boolean(),
      })
      .required(),
  })
  .required();

export type GraphileCronItemPayload = z.infer<
  typeof GraphileCronItemPayloadSchema
>;

// TODO: replace this with Redis cache information
// tslint:disable-next-line variable-name
export const ProfileSendingAccountPayloadSchema = z
  .object({
    encrypted_client_access_token: z.string(),
    profile_id: z.string().uuid(),
    reply_webhook_url: z.string().url(),
    message_status_webhook_url: z.string().url(),
    voice_callback_url: z.string().url().nullable(),
    tendlc_campaign_id: z.string().uuid().nullable(),
    service: z.nativeEnum(Service),
    sending_account_id: z.string().uuid(),
  })
  .required();

export type ProfileSendingAccountPayload = z.infer<
  typeof ProfileSendingAccountPayloadSchema
>;

// tslint:disable-next-line variable-name
export const PurchaseNumberPayloadSchema =
  ProfileSendingAccountPayloadSchema.extend({
    id: z.string(),
    area_code: z.string(),
    sending_account_id: z.string(),
    sending_location_id: z.string(),
  }).required();

export type PurchaseNumberPayload = z.infer<typeof PurchaseNumberPayloadSchema>;
