import { z } from 'zod';

import { ProfileRecord, WrappableTask } from '../lib/types';

export const RESOLVE_MESSAGES_AWAITING_FROM_NUMBER_IDENTIFIER =
  'resolve-messages-awaiting-from-number';

// tslint:disable-next-line variable-name
export const ResolveMessagesAwaitingFromNumberPayloadSchema = z
  .object({
    id: z.string().uuid(),
    phone_number: z.string(),
    sending_location_id: z.string().uuid(),
  })
  .required();

export type ResolveMessagesAwaitingFromNumberPayload = z.infer<
  typeof ResolveMessagesAwaitingFromNumberPayloadSchema
>;

export const resolveMessagesAwaitingFromNumber: WrappableTask = async (
  client,
  rawPayload
) => {
  const payload =
    ResolveMessagesAwaitingFromNumberPayloadSchema.parse(rawPayload);
  const {
    rows: [{ throughput_interval, throughput_limit }],
  } = await client.query<
    Pick<ProfileRecord, 'throughput_interval' | 'throughput_limit'>
  >(
    `
      select throughput_interval, throughput_limit
      from sms.profiles profiles
      join sms.sending_locations locations on locations.profile_id = profiles.id
      where locations.id = $1
    `,
    [payload.sending_location_id]
  );
  await client.query(
    `
      with
        deleted_afn as (
          delete from sms.outbound_messages_awaiting_from_number
          where pending_number_request_id = $1
          returning *
        ),
        interval_waits as (
          select
            id,
            to_number,
            original_created_at,
            sum(estimated_segments) over (partition by 1 order by original_created_at) as nth_segment
          from (
            select id, to_number, estimated_segments, original_created_at
            from deleted_afn
          ) all_messages
        )
        insert into sms.outbound_messages_routing
          (
            id,
            to_number,
            estimated_segments,
            decision_stage,
            sending_location_id,
            pending_number_request_id,
            processed_at,
            original_created_at,
            from_number,
            stage,
            first_from_to_pair_of_day,
            send_after,
            profile_id
          )
        select
            afn.id,
            afn.to_number,
            estimated_segments,
            decision_stage,
            sending_location_id,
            pending_number_request_id,
            processed_at,
            afn.original_created_at,
            $2 as from_number,
            'queued' as stage,
            true as first_from_to_pair_of_day,
            now() + ((interval_waits.nth_segment / $3) * $4::interval) as send_after,
            profile_id
        from deleted_afn afn
        join interval_waits on interval_waits.id = afn.id;
    `,
    [payload.id, payload.phone_number, throughput_limit, throughput_interval]
  );
};
