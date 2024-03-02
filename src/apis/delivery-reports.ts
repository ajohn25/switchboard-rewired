import express from 'express';
import isNil from 'lodash/isNil';
import {
  ArraySqlToken,
  DatabaseTransactionConnection,
  JsonSqlToken,
  NotFoundError,
} from 'slonik';

import config from '../config';
import { pool, sql } from '../db';
import {
  FORWARD_DELIVERY_REPORT_IDENTIFIER,
  ForwardDeliveryReportPayload,
} from '../jobs/forward-delivery-report';
import { delivery_reports, outbound_messages_routing } from '../lib/db-types';
import { getTelcoClient } from '../lib/services';
import { DlrResolutionInfo } from '../lib/services/service';
import {
  DeliveryReport,
  DeliveryReportEvent,
  ProfileInfo,
  SendingAccount,
} from '../lib/types';
import { logger } from '../logger';

type MessageInfo = Pick<
  ProfileInfo,
  | 'message_status_webhook_url'
  | 'reply_webhook_url'
  | 'encrypted_client_access_token'
> &
  Required<Pick<outbound_messages_routing, 'profile_id'>> & {
    original_created_at: string;
  };

type ResolvedDeliveryReportRecord = Omit<
  delivery_reports,
  | 'message_id'
  | 'created_at'
  | 'generated_at'
  | 'event_type'
  | 'error_codes'
  | 'extra'
> & {
  message_id: string;
  created_at: string;
  generated_at: string;
  event_type: DeliveryReportEvent;
  error_codes: string[];
  extra: any;
};

const app = express();

const insertResolvedDeliveryReport = async (
  trx: DatabaseTransactionConnection,
  dlrResolutionInfo: DlrResolutionInfo,
  messageServiceId: string,
  eventType: DeliveryReportEvent,
  generatedAtIso: string,
  service: string,
  validated: boolean,
  errorCodesVal: ArraySqlToken | null,
  extraJson: JsonSqlToken | null
): Promise<void> => {
  const { messageId, originalCreatedAt, numSegments, numMedia } =
    dlrResolutionInfo;

  // Future work: message info for recent messages could be stored in Redis with expiration, falling back to DB lookup
  const messageInfo = await trx.one<MessageInfo>(sql`
    select
      routing.original_created_at::text as original_created_at,
      routing.profile_id,
      profiles.message_status_webhook_url,
      profiles.reply_webhook_url,
      clients.access_token as encrypted_client_access_token
    from sms.outbound_messages_routing routing
    join sms.profiles on profiles.id = routing.profile_id
    join billing.clients as clients on clients.id = profiles.client_id
    where true
      and routing.id = ${messageId}
      and routing.original_created_at = ${originalCreatedAt}
  `);

  const { original_created_at, ...otherMessageInfo } = messageInfo;

  const deliveryReportRecord = await trx.one<ResolvedDeliveryReportRecord>(sql`
    insert into sms.delivery_reports (
      message_id,
      message_service_id,
      event_type,
      generated_at,
      created_at,
      service,
      validated,
      error_codes,
      extra
    ) values (
      ${messageId},
      ${messageServiceId},
      ${eventType},
      ${generatedAtIso},
      ${original_created_at},
      ${service},
      ${validated},
      ${errorCodesVal},
      ${extraJson}
    )
    returning *
  `);

  // Slonik returns timestamps as Unix epochs, not ISO strings. Ignore the returned value in favor of ISO string
  const {
    extra,
    generated_at: _generatedAtEpoch,
    ...record
  } = deliveryReportRecord;
  const combinedExtra = {
    ...extra,
    num_segments: numSegments,
    num_media: numMedia,
  };

  const payload: ForwardDeliveryReportPayload = {
    ...record,
    ...otherMessageInfo,
    extra: combinedExtra,
    generated_at: generatedAtIso,
  };

  await trx.maybeOne(sql`
    select graphile_worker.add_job(
      ${FORWARD_DELIVERY_REPORT_IDENTIFIER},
      payload => ${sql.json(payload as any)},
      priority => 100,
      max_attempts => 6,
      run_at => now()
    )
  `);
};

const insertUnresolvedDeliveryReport = async (
  trx: DatabaseTransactionConnection,
  messageServiceId: string,
  eventType: DeliveryReportEvent,
  generatedAtIso: string,
  service: string,
  validated: boolean,
  errorCodesVal: ArraySqlToken | null,
  extraJson: JsonSqlToken | null
): Promise<void> => {
  await trx.maybeOne(sql`
    insert into sms.unmatched_delivery_reports (
      event_type,
      message_service_id,
      generated_at,
      validated,
      error_codes,
      service,
      extra
    ) values (
      ${eventType},
      ${messageServiceId},
      ${generatedAtIso},
      ${validated},
      ${errorCodesVal},
      ${service},
      ${extraJson}
    )
  `);
};

const updateMessageCost = async (
  trx: DatabaseTransactionConnection,
  messageServiceId: string,
  costInCents: number
) => {
  await trx.maybeOne(sql`
    update sms.outbound_messages_telco
    set cost_in_cents = ${costInCents}
    where service_id = ${messageServiceId}
      and original_created_at >= date_trunc('day', 'now'::timestamp)
  `);
};

const insertDeliveryReport = async (
  report: DeliveryReport,
  dlrResolutionInfo?: DlrResolutionInfo
): Promise<void> => {
  const {
    errorCodes,
    eventType,
    messageServiceId,
    generatedAt,
    extra,
    service,
    validated,
    costInCents,
  } = report;
  const generatedAtIso = generatedAt.toISOString();
  const errorCodesVal = errorCodes ? sql.array(errorCodes, 'text') : null;
  const extraJson = extra ? sql.json(extra as any) : null;

  await pool.transaction(async (trx) => {
    const insertUnresolved = async () =>
      insertUnresolvedDeliveryReport(
        trx,
        messageServiceId,
        eventType,
        generatedAtIso,
        service,
        validated,
        errorCodesVal,
        extraJson
      );

    if (dlrResolutionInfo) {
      try {
        // Telco callback included the Switchboard message ID and we can bypass batch message ID resolution
        await insertResolvedDeliveryReport(
          trx,
          dlrResolutionInfo,
          messageServiceId,
          eventType,
          generatedAtIso,
          service,
          validated,
          errorCodesVal,
          extraJson
        );
      } catch (err) {
        if (err instanceof NotFoundError) {
          await insertUnresolved();
        } else {
          throw err;
        }
      }
    } else {
      // Telco callback does not include the Switchboard message ID and must be resolved as part of batch
      await insertUnresolved();
    }

    if (config.trackCost && !isNil(costInCents)) {
      await updateMessageCost(trx, messageServiceId, costInCents);
    }
  });
};

app.post('/:sendingAccount', async (req, res) => {
  const sendingAccountId = req.params.sendingAccount;
  let sendingAccount: SendingAccount;
  try {
    sendingAccount = await pool.one<SendingAccount>(
      sql`select * from sms.sending_accounts_as_json where id = ${sendingAccountId}`
    );
  } catch {
    return res
      .status(404)
      .json({ error: 'No matching profile for incoming delivery report' });
  }

  try {
    const telcoClient = getTelcoClient(sendingAccount);
    const { deliveryReport, dlrResolutionInfo } =
      await telcoClient.parseDeliveryReport({ req });
    await insertDeliveryReport(deliveryReport, dlrResolutionInfo);
    return res.sendStatus(200);
  } catch (ex) {
    logger.error('Got error', ex);
    return res.sendStatus(200);
  }
});

export default app;
