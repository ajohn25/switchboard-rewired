import faker from 'faker';
import { quickAddJob, runOnce, Task } from 'graphile-worker';
import nock from 'nock';
import { Pool } from 'pg';

import config from '../../config';
import {
  SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
  summarizeRecentFailedJobs,
} from '../../jobs/maintenance/summarize-recent-failed-jobs';
import { GraphileCronItemPayload } from '../../jobs/schema-validation';
import { failedJobParker } from '../../lib/worker';

let pool: Pool;

const WEBHOOK_URL = 'https://example.com/events';

const getJobCount = async (pgPool: Pool, taskIdentifier: string) => {
  const { rowCount: jobsRowCount } = await pgPool.query(
    `
      select *
      from graphile_worker.jobs
      join graphile_worker.tasks on jobs.task_id = tasks.id
      where tasks.identifier = $1
    `,
    [taskIdentifier]
  );

  return jobsRowCount;
};

const getParkedJobCount = async (pgPool: Pool, taskIdentifier: string) => {
  const { rowCount: parkedJobsRowCount } = await pgPool.query(
    `
      select *
      from worker.failed_jobs
      join graphile_worker.tasks on failed_jobs.task_id = tasks.id
      where tasks.identifier = $1
    `,
    [taskIdentifier]
  );

  return parkedJobsRowCount;
};

const setRunAtNow = async (pgPool: Pool, jobId: string) => {
  // Set 10 seconds into the past to ensure the job is picked up by the next graphile_worker.get_jobs()
  await pgPool.query(
    `
      update graphile_worker.jobs
      set run_at = now() - '10 second'::interval
      where id = $1
    `,
    [jobId]
  );
};

beforeAll(async () => {
  pool = new Pool({ connectionString: config.databaseUrl });
  Object.defineProperty(config, 'adminActionWebhookUrl', {
    value: WEBHOOK_URL,
  });
});

afterAll(async () => {
  await pool.end();
});

describe('park failed jobs', () => {
  it('parks a job after max attempts', async () => {
    const maxAttempts = 2 + Math.floor(Math.random() * 4);
    const taskIdentifier = faker.lorem.slug(4);

    const failingTask: Task = (_payload, _helpers) => {
      throw new Error('this must not go on!');
    };

    const job = await quickAddJob(
      { pgPool: pool },
      taskIdentifier,
      {},
      { maxAttempts }
    );

    const oneShot = () =>
      runOnce({
        pgPool: pool,
        taskList: {
          [taskIdentifier]: failedJobParker(failingTask),
        },
      });

    for (const _attempt of [...Array(maxAttempts - 1)]) {
      await oneShot();
      // Override graphile-worker's exponential backoff for testing
      await setRunAtNow(pool, job.id);
    }

    const penultimateJobsRowCount = await getJobCount(pool, taskIdentifier);
    const penultimateParkedJobsRowCount = await getParkedJobCount(
      pool,
      taskIdentifier
    );

    // Ensure we are not parking the task early
    expect(penultimateJobsRowCount).toBe(1);
    expect(penultimateParkedJobsRowCount).toBe(0);

    // Run final attempt
    await oneShot();

    const jobsRowCount = await getJobCount(pool, taskIdentifier);
    const parkedJobsRowCount = await getParkedJobCount(pool, taskIdentifier);

    expect(jobsRowCount).toBe(0);
    expect(parkedJobsRowCount).toBe(1);

    const payload: GraphileCronItemPayload = {
      _cron: {
        ts: new Date().toISOString(),
        backfilled: false,
      },
    };
    await quickAddJob(
      { pgPool: pool },
      SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER,
      payload
    );

    const scope = nock('https://example.com').post('/events').reply(200);

    await runOnce({
      pgPool: pool,
      taskList: {
        [SUMMARIZE_RECENT_FAILED_JOBS_IDENTIFIER]: summarizeRecentFailedJobs,
      },
    });

    expect(scope.isDone()).toBe(true);
  });
});
