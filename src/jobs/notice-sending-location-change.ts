import { PoolClient } from 'pg';

import { sending_locations } from '../lib/db-types';
import { SwitchboardEmitter } from '../lib/emitter';
import { SendingLocationRecordSchema, WrappableTask } from '../lib/types';

export const NOTICE_SENDING_LOCATION_CHANGE_IDENTIFIER =
  'notice-sending-location-change';

// tslint:disable-next-line variable-name
export const NoticeSendingLocationChangePayloadSchema =
  SendingLocationRecordSchema;

export const noticeSendingLocationChange: WrappableTask = async (
  client: PoolClient,
  rawPayload
) => {
  const payload = NoticeSendingLocationChangePayloadSchema.parse(rawPayload);
  SwitchboardEmitter.emit(
    payload.profile_id,
    'modified:sending_locations',
    payload as unknown as sending_locations
  );
};
