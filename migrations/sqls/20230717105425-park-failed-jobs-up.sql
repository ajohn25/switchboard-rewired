-- Create parked jobs table
-- ----------------------------

create schema worker;

create table worker.failed_jobs (
 id bigint,
 job_queue_id integer,
 task_id integer not null,
 payload json not null,
 priority smallint not null,
 max_attempts smallint not null,
 last_error text,
 created_at timestamp with time zone not null,
 failed_at timestamp with time zone not null default now(),
 key text,
 revision integer not null,
 flags jsonb
);

comment on column worker.failed_jobs.failed_at is E'This is a proxy for run_at';
