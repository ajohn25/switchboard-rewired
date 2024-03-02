import dbMigrate from 'db-migrate';
import { makeWorkerUtils } from 'graphile-worker';
import nock from 'nock';

import config from '../config';
import { db, sql } from '../db';
import { errToObj, logger } from '../logger';

export default async () => {
  nock.disableNetConnect();
  nock.enableNetConnect('127.0.0.1');
  try {
    // Down migration now includes making outbound_messages.sending_location_id not null
    // But previous tests may have inserted records that violate this
    await db(sql`delete from sms.outbound_messages`);
  } catch (ex: any) {
    // No-op: the down migration already ran successfully or we are on a fresh DB
    const runningOnEmptyDb =
      ex.code === '42P01' &&
      ex.message === 'relation "sms.outbound_messages" does not exist';
    if (!runningOnEmptyDb) {
      // This log helps diagnose bad testing environment setup, such as missing
      // the correct database, PG not running, etc.
      logger.error(errToObj(ex));
    }
  } finally {
    const workerUtils = await makeWorkerUtils({
      connectionString: config.databaseUrl,
    });
    await workerUtils.migrate();
    await workerUtils.release();
    const dbmigrate = dbMigrate.getInstance(true);
    dbmigrate.silence(true);
    await dbmigrate.reset();
    await dbmigrate.up();
    await db(sql`delete from graphile_worker.jobs`);
  }
};
