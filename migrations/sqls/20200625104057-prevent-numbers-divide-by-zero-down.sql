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
