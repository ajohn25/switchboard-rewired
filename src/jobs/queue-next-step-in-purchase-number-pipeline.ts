import type { PoolClient } from 'pg';

import { withinTransaction } from '../lib/db';
import { phone_number_requests } from '../lib/db-types';
import { SwitchboardEmitter } from '../lib/emitter';
import { Service } from '../lib/types';
import { logger } from '../logger';
import { profileConfigCache, sendingAccountCache } from '../models/cache';

// Wrapped tasks
import { AssociateService10DLCCampaignPayload } from './associate-service-10dlc-campaign';
import { AssociateServiceProfilePayload } from './associate-service-profile';
import { PollNumberOrderPayload } from './poll-number-order';
import { PurchaseNumberPayload } from './schema-validation';

export type PayloadOptions =
  | AssociateService10DLCCampaignPayload
  | AssociateServiceProfilePayload
  | PollNumberOrderPayload
  | PurchaseNumberPayload;

type TaskName =
  | 'poll-number-order'
  | 'associate-service-10dlc-campaign'
  | 'associate-service-profile'
  | 'purchase-number';

type WrappedTask<Payload extends PayloadOptions, Result> = (
  client: PoolClient,
  payload: Payload
) => Promise<Result>;

/*
 * This logic is originally replacing these triggers as of 2022/09/21
 * These have been copied from the DB and then sorted according to service/path chronology
 * 
 * Triggers:
 * 	-- Bandwidth - grey route
    _500_bandwidth_complete_basic_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()

 * 	-- Bandwidth - 10dlc
    _500_bandwidth_associate_10dlc_campaign AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL) EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign')
    _500_bandwidth_complete_10dlc_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'bandwidth'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()

 * -- Telnyx - shared
    _500_telnyx_associate_service_profile AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.phone_number IS NOT NULL AND old.service_order_completed_at IS NULL AND new.service_order_completed_at IS NOT NULL) EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-profile')

 * -- Telnyx - grey route
    _500_telnyx_complete_basic_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NULL AND old.service_profile_associated_at IS NULL AND new.service_profile_associated_at IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()

 * -- Telnyx - 10dlc
    _500_telnyx_associate_10dlc_campaign AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.service_profile_associated_at IS NULL AND new.service_profile_associated_at IS NOT NULL) EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign')
    _500_telnyx_complete_10dlc_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'telnyx'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()

 * -- Twilio - grey route
    _500_twilio_complete_basic_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NULL AND old.phone_number IS NULL AND new.phone_number IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()
	
 * -- Twilio - 10dlc
    _500_twilio_associate_service_profile AFTER UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.phone_number IS NULL AND new.phone_number IS NOT NULL) EXECUTE FUNCTION trigger_job_with_sending_account_and_profile_info('associate-service-10dlc-campaign')
    _500_twilio_complete_10dlc_purchase BEFORE UPDATE ON sms.phone_number_requests FOR EACH ROW WHEN (new.service = 'twilio'::sms.profile_service_option AND new.service_10dlc_campaign_id IS NOT NULL AND old.service_10dlc_campaign_associated_at IS NULL AND new.service_10dlc_campaign_associated_at IS NOT NULL) EXECUTE FUNCTION sms.tg__complete_number_purchase()
 */

// Use string values here to avoid TS2553 (Computed values are not permitted in an enum with string valued members.)
enum NextAction {
  CompletePurchase = 'complete-purchase',
  QueuePollNumberOrder = 'poll-number-order',
  QueueAssociateServiceProfile = 'associate-service-profile',
  QueueAssociateService10DLCCampaign = 'associate-service-10dlc-campaign',
}

type AggregatorService = Exclude<Service, 'tcr'>;

const getNextAction = (
  service: AggregatorService,
  is10dlc: boolean,
  justCompletedTaskName: TaskName
): NextAction => {
  switch (service) {
    case Service.Bandwidth:
    case Service.BandwidthDryRun:
      switch (justCompletedTaskName) {
        case 'purchase-number':
          return NextAction.QueuePollNumberOrder;

        case 'poll-number-order':
          return is10dlc
            ? NextAction.QueueAssociateService10DLCCampaign
            : NextAction.CompletePurchase;

        case 'associate-service-10dlc-campaign':
          return NextAction.CompletePurchase;
      }

    case Service.Telnyx:
      switch (justCompletedTaskName) {
        case 'purchase-number':
          return NextAction.QueuePollNumberOrder;

        case 'poll-number-order':
          return NextAction.QueueAssociateServiceProfile;

        case 'associate-service-profile':
          return is10dlc
            ? NextAction.QueueAssociateService10DLCCampaign
            : NextAction.CompletePurchase;

        case 'associate-service-10dlc-campaign':
          return NextAction.CompletePurchase;
      }

    case Service.Twilio:
      switch (justCompletedTaskName) {
        case 'purchase-number':
          return is10dlc
            ? NextAction.QueueAssociateService10DLCCampaign
            : NextAction.CompletePurchase;

        case 'associate-service-10dlc-campaign':
          return NextAction.CompletePurchase;
      }
  }

  logger.error(
    'Oops, we reached a service/task branch that should be impossible: ',
    { justCompletedTaskName, service, is10dlc }
  );

  throw new Error(
    `Oops, we reached a service/task branch that should be impossible: ${JSON.stringify(
      { justCompletedTaskName, service, is10dlc }
    )}`
  );
};

export const queuePhoneNumberRequestJob = async (
  client: PoolClient,
  jobName: string,
  phoneNumberRequestId: string
) => {
  await client.query(
    `
      select add_job_with_sending_account_and_profile_info(
        $1, 
        ( select row_to_json(pnr)
          from sms.phone_number_requests pnr 
          where id = $2
        )
      )
    `,
    [jobName, phoneNumberRequestId]
  );
};

export const wrapWithQueueNextStepInPurchaseNumberPipeline = <
  Payload extends PayloadOptions,
  Result
>(
  taskName: TaskName,
  task: WrappedTask<Payload, Result>
) => {
  return async (client: PoolClient, payload: Payload) => {
    return withinTransaction(client, async (trx) => {
      const result = await task(trx, payload);

      const sendingAccount = await sendingAccountCache.getSendingAccount(
        trx,
        payload.sending_account_id
      );

      if (!('profile_id' in payload)) {
        throw new Error('Missing profile_id in payload');
      }

      const profileConfig = await profileConfigCache.getProfileConfig(
        trx,
        payload.profile_id
      );

      const nextAction = getNextAction(
        sendingAccount.service as AggregatorService,
        !!profileConfig.tendlc_campaign_id,
        taskName
      );

      switch (nextAction) {
        case NextAction.CompletePurchase:
          await trx.query(
            'update sms.phone_number_requests set fulfilled_at = now() where id = $1',
            [payload.id]
          );
          break;

        default:
          // For all other branches, we're queueing trigger_job_with_sending_account_and_profile_info with
          // nextAction as the task name and the phone_number_request as the payload
          await queuePhoneNumberRequestJob(trx, nextAction, payload.id);
          break;
      }

      return result;
    });
  };
};

/**
 * This is a testing utility function that takes the place of directly setting
 * service_order_completed_at, fulfilled_at, etc. properties during tests
 * in order to validate that triggers are created
 *
 * It is useful as an alternative to running the actual task since it spares
 * the test the burden of mocking Twilio/Telnyx/Bandwidth for real
 * task success
 *
 * @param client
 * @param sendingAccountId
 * @param profileId
 * @param fakeJustCompletedTaskName
 * @param pendingNumberRequestId
 */
export const queueNextStepAsIfJobRan = async (
  client: PoolClient,
  sendingAccountId: string,
  profileId: string,
  fakeJustCompletedTaskName: TaskName,
  pendingNumberRequestId: string
) => {
  const sendingAccount = await sendingAccountCache.getSendingAccount(
    client,
    sendingAccountId
  );

  const profileConfig = await profileConfigCache.getProfileConfig(
    client,
    profileId
  );

  const nextAction = getNextAction(
    sendingAccount.service as AggregatorService,
    !!profileConfig.tendlc_campaign_id,
    fakeJustCompletedTaskName
  );

  switch (nextAction) {
    case NextAction.CompletePurchase:
      const {
        rows: [fulfilledPhoneNumberRequest],
      } = await client.query<phone_number_requests>(
        'update sms.phone_number_requests set fulfilled_at = now() where id = $1 returning *',
        [pendingNumberRequestId]
      );

      SwitchboardEmitter.emit(
        profileConfig.id,
        'fulfilled:phone_number_request',
        fulfilledPhoneNumberRequest
      );

    default:
      // For all other branches, we're queueing trigger_job_with_sending_account_and_profile_info with
      // nextAction as the task name and the phone_number_request as the payload
      await queuePhoneNumberRequestJob(
        client,
        nextAction,
        pendingNumberRequestId
      );
  }
};
