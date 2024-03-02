import {
  CronItem,
  LogFunctionFactory,
  Logger as GraphileWorkerLogger,
  parseCronItems,
  run as runGraphileWorker,
  TaskList,
} from 'graphile-worker';
import fromPairs from 'lodash/fromPairs';
import toPairs from 'lodash/toPairs';

import config from './config';
import {
  ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER,
  associateService10DLCCampaign,
} from './jobs/associate-service-10dlc-campaign';
import {
  ASSOCIATE_SERVICE_PROFILE_IDENTIFIER,
  associateServiceProfile,
} from './jobs/associate-service-profile';
import {
  ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER,
  associateServiceProfileToNumber,
} from './jobs/associate-service-profile-to-phone-number';
import { BACKFILL_COST_IDENTIFIER, backfillCost } from './jobs/backfill-cost';
import {
  ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER,
  estimateAreaCodeCapacity,
} from './jobs/estimate-area-code-capacity';
import {
  FIND_SUITABLE_AREA_CODES_IDENTIFIER,
  findSuitableAreaCodes,
} from './jobs/find-suitable-area-codes';
import { FLUSH_REDIS_IDENTIFIER, flushRedis } from './jobs/flush-redis';
import {
  FORWARD_DELIVERY_REPORT_IDENTIFIER,
  forwardDeliveryReport,
} from './jobs/forward-delivery-report';
import {
  FORWARD_INBOUND_MESSAGE_IDENTIFIER,
  forwardInboundMessage,
} from './jobs/forward-inbound-message';
import { LOOKUP_IDENTIFIER, performLookup } from './jobs/lookup';
import {
  SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
  summarizeRecentFailedJobs,
  summarizeRecentFailedJobsCronItem,
} from './jobs/maintenance/summarize-recent-failed-jobs';
import {
  VACUUM_FULL_TABLE_IDENTIFIER,
  vacuumCronItems,
  vacuumFullTable,
} from './jobs/maintenance/vacuum-full-table';
import {
  NOTICE_SENDING_LOCATION_CHANGE_IDENTIFIER,
  noticeSendingLocationChange,
} from './jobs/notice-sending-location-change';
import {
  POLL_NUMBER_ORDER_IDENTIFIER,
  pollNumberOrder,
} from './jobs/poll-number-order';
import {
  process10DlcMessage,
  PROCESS_10DLC_MESSAGE_IDENTIFIER,
} from './jobs/process-10dlc-message';
import {
  PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER,
  PROCESS_MESSAGE_IDENTIFIER,
  processGreyRouteMessage,
} from './jobs/process-grey-route-message';
import {
  PROCESS_TOLL_FREE_MESSAGE_IDENTIFIER,
  processTollFreeMessage,
} from './jobs/process-toll-free-message';
import {
  PURCHASE_NUMBER_IDENTIFIER,
  purchaseNumber,
} from './jobs/purchase-number';
import {
  QUEUE_COST_BACKFILL_IDENTIFIER,
  queueCostBackfill,
} from './jobs/queue-cost-backfill';
import {
  RESOLVE_DELIVERY_REPORTS_IDENTIFIER,
  resolveDeliveryReports,
} from './jobs/resolve-delivery-reports';
import {
  RESOLVE_MESSAGES_AWAITING_FROM_NUMBER_IDENTIFIER,
  resolveMessagesAwaitingFromNumber,
} from './jobs/resolve-messages-awaiting-from-number';
import { ROLLUP_USAGE_IDENTIFIER, rollupUsage } from './jobs/rollup-usage';
import { SELL_NUMBER_IDENTIFIER, sellNumber } from './jobs/sell-number';
import { SEND_MESSAGE_IDENTIFIER, sendMessage } from './jobs/send-message';
import {
  TRUNCATE_DAILY_TABLES_IDENTIFIER,
  truncateDailyTables,
} from './jobs/truncate-daily-tables';
import { failedJobParker, wrapSwitchboardTask } from './lib/worker';
import { WorkerEventEmitter } from './lib/worker-event-emitter';
import { logger } from './logger';

const createGraphileLogger = () => {
  const logFactory: LogFunctionFactory = (scope) => (level, message, meta) =>
    logger.log({ level, message, ...meta, ...scope });

  const graphileLogger = new GraphileWorkerLogger(logFactory);
  return graphileLogger;
};

const GRAPHILE_WORKER_AGGREGATE_CONCURRENCY = config.graphileWorkerConcurrency;

const sharedTaskList = {
  [NOTICE_SENDING_LOCATION_CHANGE_IDENTIFIER]: noticeSendingLocationChange,
  // originally assemble worker
  [ASSOCIATE_SERVICE_10DLC_CAMPAIGN_IDENTIFIER]: associateService10DLCCampaign,
  [ASSOCIATE_SERVICE_PROFILE_IDENTIFIER]: associateServiceProfile,
  [ESTIMATE_AREA_CODE_CAPACITY_IDENTIFIER]: estimateAreaCodeCapacity,
  [FIND_SUITABLE_AREA_CODES_IDENTIFIER]: findSuitableAreaCodes,
  [FORWARD_DELIVERY_REPORT_IDENTIFIER]: forwardDeliveryReport,
  [FORWARD_INBOUND_MESSAGE_IDENTIFIER]: forwardInboundMessage,
  [LOOKUP_IDENTIFIER]: performLookup,
  [POLL_NUMBER_ORDER_IDENTIFIER]: pollNumberOrder,
  [PROCESS_GREY_ROUTE_MESSAGE_IDENTIFIER]: processGreyRouteMessage,
  [PROCESS_MESSAGE_IDENTIFIER]: processGreyRouteMessage,
  [PROCESS_TOLL_FREE_MESSAGE_IDENTIFIER]: processTollFreeMessage,
  [PURCHASE_NUMBER_IDENTIFIER]: purchaseNumber,
  [SELL_NUMBER_IDENTIFIER]: sellNumber,
  [SEND_MESSAGE_IDENTIFIER]: sendMessage,
  // originally graphile worker
  [ASSOCIATE_SERVICE_PROFILE_TO_PHONE_NUMBER_IDENTIFIER]:
    associateServiceProfileToNumber,
  [RESOLVE_MESSAGES_AWAITING_FROM_NUMBER_IDENTIFIER]:
    resolveMessagesAwaitingFromNumber,
  [PROCESS_10DLC_MESSAGE_IDENTIFIER]: process10DlcMessage,
};

const graphileWorkerTaskListOverlap: TaskList = Object.entries(
  sharedTaskList
).reduce((acc, [key, task]) => {
  return { ...acc, [key]: wrapSwitchboardTask(task) };
}, {});

const graphileWorkerOnly: TaskList = {
  [BACKFILL_COST_IDENTIFIER]: backfillCost,
  [QUEUE_COST_BACKFILL_IDENTIFIER]: queueCostBackfill,
  [RESOLVE_DELIVERY_REPORTS_IDENTIFIER]: resolveDeliveryReports,
  [ROLLUP_USAGE_IDENTIFIER]: rollupUsage,
  [TRUNCATE_DAILY_TABLES_IDENTIFIER]: truncateDailyTables,
  [FLUSH_REDIS_IDENTIFIER]: flushRedis,
  [VACUUM_FULL_TABLE_IDENTIFIER]: vacuumFullTable,
  [SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER]: summarizeRecentFailedJobs,
};

const wrappedGraphileWorkerTasks: TaskList = Object.entries(
  graphileWorkerOnly
).reduce((acc, [key, task]) => {
  return { ...acc, [key]: failedJobParker(task) };
}, {});

const graphileWorkerTaskList = {
  ...graphileWorkerTaskListOverlap,
  ...wrappedGraphileWorkerTasks,
};

export default {
  start: async (databaseUrl: string) => {
    const graphileWorkerTl = fromPairs(
      toPairs(graphileWorkerTaskList).filter(
        ([taskName, _task]) =>
          config.jobsToRun === undefined || config.jobsToRun.includes(taskName)
      )
    );

    const historicCronItems: CronItem[] = [
      {
        task: RESOLVE_DELIVERY_REPORTS_IDENTIFIER,
        match: '* * * * *', // Every minute
      },
      {
        task: QUEUE_COST_BACKFILL_IDENTIFIER,
        match: '0 5 * * *', // 0500 UTC daily
      },
      {
        task: ROLLUP_USAGE_IDENTIFIER,
        match: '2 */1 * * *', // start rollup 2 minutes after the hour to account for stragglers
      },
      {
        task: FLUSH_REDIS_IDENTIFIER,
        match: '0 5 * * *', // 0500 UTC daily
      },
    ];

    const cronItems: CronItem[] = [
      ...historicCronItems,
      ...vacuumCronItems,
      summarizeRecentFailedJobsCronItem,
    ];

    await runGraphileWorker({
      concurrency: GRAPHILE_WORKER_AGGREGATE_CONCURRENCY,
      connectionString: databaseUrl,
      logger: createGraphileLogger(),
      pollInterval: 1000,
      taskList: graphileWorkerTl,
      parsedCronItems: parseCronItems(cronItems),
      events: WorkerEventEmitter,
    });
  },
};
