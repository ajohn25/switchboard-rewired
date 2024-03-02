create schema lookup;
create extension if not exists pgcrypto with schema public;
create extension if not exists "uuid-ossp" with schema public;

do $$
begin
  create role administrator;
  exception when duplicate_object then
  raise notice 'not creating role administrator -- it already exists';
end
$$;


do $$
begin
  create role client;
  exception when duplicate_object then
  raise notice 'not creating role client -- it already exists';
end
$$;

/**
 * Define custom types
 */

create domain phone_number as text constraint e164 check (value ~* '\+1[0-9]{10}');

create type lookup.phone_type_enum as enum (
  'landline',
  'mobile',
  'voip',
  'unknown',
  'invalid'
);

create type lookup.billing_status_enum as enum (
  'billed',
  'cached'
);

create type lookup.service_option as enum (
  'telnyx'
);

create type lookup.access_fulfillment_state as enum (
  'done',
  'waiting',
  'fetching'
);

create type lookup.request_progress_result as (
  completed_at timestamp,
  progress numeric
);

/**
 * Define auth utility functions / tables
 */

create table lookup.clients (
  id uuid primary key default uuid_generate_v1mc(),
  name text unique not null,
  access_token text unique default MD5(random()::text),
  created_at timestamp not null default now()
);

create index client_access_token_idx on lookup.clients(access_token);

create or replace function lookup.current_client_id() returns uuid as $$
  select current_setting('client.id')::uuid
$$ language sql stable set search_path from current;

/**
 * Define tables
 */

create table lookup.phone_data (
  phone_number phone_number primary key,
  carrier_name text,
  phone_type lookup.phone_type_enum not null,
  last_updated_at timestamp default now()
); 

create index phone_data_updated_at_idx on lookup.phone_data (last_updated_at);

comment on table lookup.phone_data is E'@omit';


create table lookup.requests (
  id uuid primary key default uuid_generate_v1mc(),
  client_id uuid not null references lookup.clients(id) default lookup.current_client_id(),
  created_at timestamp not null default now(),
  closed_at timestamp,
  completed_at timestamp
);

create index request_client_id_idx on lookup.requests (client_id);

comment on table lookup.requests is E'
@omit update
';

create table lookup.accesses (
  id uuid primary key default uuid_generate_v1mc(), 
  client_id uuid not null references lookup.clients(id) default lookup.current_client_id(),
  request_id uuid references lookup.requests(id), -- nullable if from json api, otherwise exists
  phone_number phone_number not null,
  accessed_at timestamp not null default now(),
  state lookup.access_fulfillment_state not null default 'waiting',
  billing_status lookup.billing_status_enum,
  constraint unique_phone_number_request unique (phone_number, request_id)
);

create index accessess_client_id_idx on lookup.accesses (client_id);
create index accessess_request_id_idx on lookup.accesses (request_id);
create index accessess_phone_number_idx on lookup.accesses (phone_number);
create index accessess_access_at_idx on lookup.accesses (accessed_at);

create table lookup.lookups (
  phone_number phone_number,
  performed_at timestamp not null default now(),
  via_service lookup.service_option not null default 'telnyx',
  carrier_name text,
  phone_type lookup.phone_type_enum not null,
  raw_result json
);

/**
 * View definitions
 */

create or replace view lookup.fresh_phone_data as
  select phone_number, carrier_name, phone_type, last_updated_at as updated_at
  from lookup.phone_data
  where last_updated_at > now() - interval '12 month'
    and (
      current_user = 'lookup'
      or current_user = 'postgres'
      or exists (
        select 1
        from lookup.accesses
        where lookup.accesses.phone_number = lookup.phone_data.phone_number
          and lookup.accesses.accessed_at > now() - interval '12 month'
      )
    );

comment on view lookup.fresh_phone_data is E'@omit';

create view lookup.request_results as
  select 
    lookup.accesses.request_id,
    lookup.accesses.phone_number,
    lookup.fresh_phone_data.phone_type
  from lookup.accesses
  join lookup.fresh_phone_data
    on lookup.fresh_phone_data.phone_number = lookup.accesses.phone_number
  where lookup.accesses.client_id = lookup.current_client_id();

comment on view lookup.request_results is E'
@foreignKey (request_id) references lookup.requests (id)
@primaryKey phone_number
';

/**
 * Function and trigger defintiions
 */

create or replace function lookup.close_request(request_id uuid) returns lookup.requests as $$
declare
  v_request_completed boolean;
  v_result lookup.requests;
  v_request_id uuid;
begin
  select request_id into v_request_id;

  select (
    select count(*)
    from lookup.accesses
    where lookup.accesses.request_id = v_request_id
      and state <> 'done'
  ) = 0
  into v_request_completed;

  if v_request_completed then
    update lookup.requests
    set completed_at = now()
    where lookup.requests.id = v_request_id;
  end if;

  update lookup.requests
  set closed_at = now()
  where id = v_request_id;

  select * from lookup.requests
  where id = v_request_id
  into v_result;

  return v_result;
end;
$$ language plpgsql strict volatile set search_path from current;

create or replace function lookup.tg__lookup__update_phone_data() returns trigger as $$
begin
  insert into lookup.phone_data (phone_number, carrier_name, phone_type)
  values (NEW.phone_number, NEW.carrier_name, NEW.phone_type)
  on conflict (phone_number) do 
    update
    set carrier_name = NEW.carrier_name,
        phone_type = NEW.phone_type,
        last_updated_at = now();
  
  return NEW;
end;
$$ language plpgsql strict volatile set search_path from current;

create or replace function lookup.tg__lookup__mark_access_done() returns trigger as $$
begin
  update lookup.accesses
  set state = 'done'::lookup.access_fulfillment_state
  where phone_number = NEW.phone_number;

  return NEW;
end;
$$ language plpgsql strict volatile set search_path from current;

create trigger _500_update_phone_data
  after insert
  on lookup.lookups
  for each row
  execute procedure lookup.tg__lookup__update_phone_data();

create trigger _500_update_related_accesses
  after insert
  on lookup.lookups
  for each row
  execute procedure lookup.tg__lookup__mark_access_done();

create or replace function lookup.request_progress(request_id uuid) returns lookup.request_progress_result as $$
declare
  v_total_accesses int;
  v_accesses_done int;
  v_completed_at timestamp;
  v_progress numeric;
  v_requests_found int;
begin
  select count(*) from lookup.requests
  where lookup.requests.id = request_progress.request_id
  into v_requests_found;

  if v_requests_found = 0 then
    raise 'No request found' using errcode = 'no_data_found';
  end if;

  select count(*)
  from lookup.accesses
  where lookup.accesses.request_id = request_progress.request_id
  into v_total_accesses;

  select count(*)
  from lookup.accesses
  where state = 'done'
    and lookup.accesses.request_id = request_progress.request_id
  into v_accesses_done;

  select null into v_completed_at;

  if v_total_accesses - v_accesses_done = 0 then
    select now() into v_completed_at;

    update lookup.requests
    set completed_at = v_completed_at
    where lookup.requests.closed_at is not null 
      and lookup.requests.id = request_progress.request_id;
  end if;

  select v_accesses_done::numeric / v_total_accesses::numeric into v_progress;
  return cast(row(v_completed_at, v_progress) as lookup.request_progress_result);
end;
$$ language plpgsql volatile set search_path from current;

create or replace function lookup.tg__access__fulfill() returns trigger as $$
declare
  v_fresh_record_exists boolean;
  v_already_fetching boolean;
  v_job_json json;
begin
  select exists(
    select 1
    from lookup.fresh_phone_data
    where 
      lookup.fresh_phone_data.phone_number = NEW.phone_number
  ) into v_fresh_record_exists;

  select exists(
    select 1
    from lookup.accesses
    where phone_number = NEW.phone_number
      and state <> 'done'
  ) into v_already_fetching;

  if not (v_fresh_record_exists or v_already_fetching) then
    select json_build_object(
      'access_id', NEW.id,
      'phone_number', NEW.phone_number
    ) into v_job_json;

    perform assemble_worker.add_job('lookup', v_job_json);
  else
    NEW.state = 'done';
  end if;

  return NEW;
end;
$$ language plpgsql strict volatile security definer set search_path from current;

create trigger _500_fulfill_access
  before insert
  on lookup.accesses
  for each row
  execute procedure lookup.tg__access__fulfill();


/**
 * RBAC
 */

alter table lookup.clients enable row level security;

create policy clients_policy
  on lookup.clients
  to client
  using (id = lookup.current_client_id());

alter table lookup.accesses enable row level security;

create policy accesess_policy
  on lookup.accesses
  to client
  using (client_id = lookup.current_client_id());

grant usage on schema lookup to client;
grant select, update, insert on lookup.requests to client;
grant select on lookup.fresh_phone_data to client;
grant select, insert on lookup.accesses to client;
grant select on lookup.clients to client;

alter table lookup.requests enable row level security;

create policy requests_policy
  on lookup.requests
  to client
  using (client_id = lookup.current_client_id());

