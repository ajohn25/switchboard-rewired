/**
 * These are the migrations to run to accomplish the changes checked into version control on Friday, Sept 13, 2019
 *
 * A simple `alter schema lookup_service rename to lookup` would be enough, but function bodies retain their full
 * schema references.
 *
 * Although the function the schema is bound to changes, any references within the function body still refer to some potential
 * other schema.
 *
 * Therefore, all of the functions that reference specific tables need to be redefined.
 *
 * Finally, we create a view on a lookup_service schema that references the lookup.fresh_phone_data view to avoid disrupting
 * workflows.
*/

alter schema lookup_service rename to lookup;

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

drop view lookup.request_results;
drop view lookup.fresh_phone_data;

create domain phone_number as text constraint e164 check (value ~* '\+1[0-9]{10}');

alter table lookup.phone_data alter column phone_number type phone_number;
alter table lookup.accesses alter column phone_number type phone_number;
alter table lookup.lookups alter column phone_number type phone_number;

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

create view lookup.request_results as
  select 
    lookup.accesses.request_id,
    lookup.accesses.phone_number,
    lookup.fresh_phone_data.phone_type
  from lookup.accesses
  join lookup.fresh_phone_data
    on lookup.fresh_phone_data.phone_number = lookup.accesses.phone_number
  where lookup.accesses.client_id = lookup.current_client_id();

comment on view lookup.fresh_phone_data is E'@omit';

comment on view lookup.request_results is E'
@foreignKey (request_id) references lookup.requests (id)
@primaryKey phone_number
';

grant select on lookup.request_results to client;

create schema lookup_service;

create view lookup_service.fresh_phone_data as select * from lookup.fresh_phone_data;
