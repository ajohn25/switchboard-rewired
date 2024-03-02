import { Job, Task } from 'graphile-worker';

import { pgPool } from '../db';

type WrappableTask = (client: any, payload: any) => Promise<any>;

export const wrapJobForGraphileWorker = (
  job: WrappableTask,
  requiresConsistentClient = false,
  requiresTransaction = false
): Task => {
  return async (payload, helpers) => {
    if (requiresConsistentClient) {
      return helpers.withPgClient(async (client) => {
        if (requiresTransaction) {
          await client.query('begin');
          try {
            await job(client, payload);
            await client.query('commit');
          } catch (ex) {
            await client.query('rollback');
            throw ex;
          }
        } else {
          await job(client, payload);
        }
      });
    }

    return job(pgPool, payload);
  };
};

const parkFailedJobQuery = (job: Job, err: unknown) => {
  // Similar logic to graphile-worker
  // https://github.com/graphile/worker/blob/4d05832a1712f456d92001514c9474da73b56901/src/worker.ts#L290-L293
  const lastErrorMessage =
    (err instanceof Error ? err.message : String(err)) ??
    'Non error or error without message thrown.';

  const query = `
    insert into worker.failed_jobs (
      id,
      job_queue_id,
      task_id,
      payload,
      priority,
      max_attempts,
      last_error,
      created_at,
      key,
      revision,
      flags
    )
    values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
  `;
  const values = [
    job.id,
    job.job_queue_id,
    job.task_id,
    job.payload,
    job.priority,
    job.max_attempts,
    lastErrorMessage,
    job.created_at,
    job.key,
    job.revision,
    job.flags,
  ];
  return { query, values };
};

export const failedJobParker =
  (task: Task): Task =>
  async (payload, helpers) => {
    try {
      await task(payload, helpers);
    } catch (err: unknown) {
      if (helpers.job.attempts === helpers.job.max_attempts) {
        const { query, values } = parkFailedJobQuery(helpers.job, err);
        await helpers.query(query, values);
      } else {
        throw err;
      }
    }
  };

export const wrapSwitchboardTask = (task: WrappableTask): Task =>
  failedJobParker(wrapJobForGraphileWorker(task));
