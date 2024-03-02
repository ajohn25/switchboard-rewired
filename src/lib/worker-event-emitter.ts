import { EventEmitter } from 'events';
import type {
  Cron,
  Job,
  Worker,
  WorkerEvents,
  WorkerPool,
} from 'graphile-worker';

import { statsd } from '../logger';

// tslint:disable-next-line variable-name
export const WorkerEventEmitter: WorkerEvents = new EventEmitter();

const WORKER_STAT_PREFIX = 'node.graphile.worker.';

const workerStats = statsd?.childClient({
  prefix: WORKER_STAT_PREFIX,
});

// WorkerPool does not expose anything we want to tag
const tagsForPool = (_pool: WorkerPool) => [];

const tagsForWorker = (worker: Worker) => [`worker_id:${worker.workerId}`];

const tagsForJob = (job: Job) => [`task_identifier:${job.task_identifier}`];

// Cron does not expose anything we want to tag
const tagsForCron = (_cron: Cron) => [];

// Runner Events

WorkerEventEmitter.on('gracefulShutdown', ({ signal }) => {
  workerStats?.increment(`gracefulShutdown`, [`signal:${signal}`]);
});

WorkerEventEmitter.on('stop', () => {
  workerStats?.increment(`stop`, []);
});

// Pool Events

WorkerEventEmitter.on('pool:create', ({ workerPool }) => {
  workerStats?.increment(`pool.create`, tagsForPool(workerPool));
});

WorkerEventEmitter.on('pool:listen:connecting', ({ workerPool }) => {
  workerStats?.increment(`pool.listen.connecting`, tagsForPool(workerPool));
});

WorkerEventEmitter.on('pool:listen:success', ({ workerPool }) => {
  workerStats?.increment(`pool.listen.success`, tagsForPool(workerPool));
});

WorkerEventEmitter.on('pool:listen:error', ({ workerPool }) => {
  workerStats?.increment(`pool.listen.error`, tagsForPool(workerPool));
});

WorkerEventEmitter.on('pool:release', ({ pool }) => {
  workerStats?.increment(`pool.release`, tagsForPool(pool));
});

WorkerEventEmitter.on('pool:gracefulShutdown', ({ pool }) => {
  workerStats?.increment(`pool.gracefulShutdown`, tagsForPool(pool));
});

WorkerEventEmitter.on('pool:gracefulShutdown:error', ({ pool }) => {
  workerStats?.increment(`pool.gracefulShutdown.error`, tagsForPool(pool));
});

// Worker Events

WorkerEventEmitter.on('worker:create', ({ worker }) => {
  workerStats?.increment(`worker.create`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:release', ({ worker }) => {
  workerStats?.increment(`worker.release`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:stop', ({ worker }) => {
  workerStats?.increment(`worker.stop`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:getJob:start', ({ worker }) => {
  workerStats?.increment(`worker.getJob.start`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:getJob:error', ({ worker }) => {
  workerStats?.increment(`worker.getJob.error`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:getJob:empty', ({ worker }) => {
  workerStats?.increment(`worker.getJob.empty`, tagsForWorker(worker));
});

WorkerEventEmitter.on('worker:fatalError', ({ worker }) => {
  workerStats?.increment(`worker.fatalError`, tagsForWorker(worker));
});

// Job Events

WorkerEventEmitter.on('job:start', ({ job }) => {
  workerStats?.increment(`job.start`, tagsForJob(job));
});

WorkerEventEmitter.on('job:success', ({ job }) => {
  workerStats?.increment(`job.success`, tagsForJob(job));
});

WorkerEventEmitter.on('job:error', ({ job }) => {
  workerStats?.increment(`job.error`, tagsForJob(job));
});

WorkerEventEmitter.on('job:failed', ({ job }) => {
  workerStats?.increment(`job.failed`, tagsForJob(job));
});

WorkerEventEmitter.on('job:complete', ({ job }) => {
  workerStats?.increment(`job.complete`, tagsForJob(job));
});

// Cron Events

WorkerEventEmitter.on('cron:starting', ({ cron }) => {
  workerStats?.increment(`cron.starting`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:started', ({ cron }) => {
  workerStats?.increment(`cron.started`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:backfill', ({ cron }) => {
  workerStats?.increment(`cron.backfill`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:prematureTimer', ({ cron }) => {
  workerStats?.increment(`cron.prematureTimer`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:overdueTimer', ({ cron }) => {
  workerStats?.increment(`cron.overdueTimer`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:schedule', ({ cron }) => {
  workerStats?.increment(`cron.schedule`, tagsForCron(cron));
});

WorkerEventEmitter.on('cron:scheduled', ({ cron, jobsAndIdentifiers }) => {
  const cronTags = tagsForCron(cron);
  jobsAndIdentifiers.forEach((jobAndIdentifier) => {
    const jobTags = [
      `cron_identifier:${jobAndIdentifier.identifier}`,
      `task_identifier:${jobAndIdentifier.job.task}`,
      `queue_name:${jobAndIdentifier.job.queueName}`,
    ];
    workerStats?.increment(`cron.scheduled.job`, [...cronTags, ...jobTags]);
  });
  workerStats?.increment(`cron.scheduled`, cronTags);
});

// Reset Locked Events

WorkerEventEmitter.on('resetLocked:started', () => {
  workerStats?.increment(`resetLocked.started`, []);
});

WorkerEventEmitter.on('resetLocked:success', () => {
  workerStats?.increment(`resetLocked.success`, []);
});

export default WorkerEventEmitter;
