import dbMigrate from 'db-migrate';
import { db, sql } from '../db';

export default async () => {
  try {
    await db(sql`delete from sms.outbound_messages`);
  } catch (ex) {
    // Running on empty db
  } finally {
    const dbmigrate = dbMigrate.getInstance(true);
    dbmigrate.silence(true);
    await dbmigrate.reset();
    await db(sql`delete from graphile_worker.jobs`);
  }
};
