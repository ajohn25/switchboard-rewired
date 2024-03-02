/*
 * Early Switchboard migrations reference various assemble-worker-created tables directly. The
 * assemble-worker library was removed from the application, however, and without assemble-worker
 * migrations running before test suites, these early Switchboard migrations will fail. The
 * assemble-worker-mock migration creates these tables in order for early Switchboard migrations
 * to succeed, and does so in a way that does not have side effects when run in production against
 * a DB where assemble-worker tables are already present.
 */

create schema if not exists assemble_worker;

DO $$ BEGIN
  create type assemble_worker.job_status as enum (
    'running',
    'waiting to run',
    'waiting to retry',
    'failed'
  );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

create table if not exists assemble_worker.pending_jobs (
  queue_name text not null,
  payload json default '{}'::json not null,
  max_attempts int default 25 not null,
  run_at timestamp,
  created_at timestamp not null default now()
);

create table if not exists assemble_worker.jobs (
  id bigserial primary key,
  queue_name text not null,
  payload json default '{}'::json not null,
  run_at timestamp,
  status assemble_worker.job_status not null,
  attempts int default 0 not null,
  max_attempts int default 25 not null,
  errors text[] default ARRAY[]::text[],
  ran_at timestamp[] default ARRAY[]::timestamp[],
  created_at timestamp not null default now()
);
