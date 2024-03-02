
drop policy requests_policy on lookup.requests;
revoke all privileges on all tables in schema lookup from administrator;
revoke all privileges on schema lookup from administrator;

do $$
begin
  drop role administrator;
  exception when dependent_objects_still_exist then
  raise notice 'not dropping role administrator -- objects in another databases rely on it';
end
$$;

revoke all privileges on all tables in schema lookup from client;
revoke all privileges on schema lookup from client;
revoke all privileges on all tables in schema assemble_worker from client;
revoke all privileges on schema assemble_worker from client;

-- affects current database only
drop owned by client;

do $$
begin
  drop role client;
  exception when dependent_objects_still_exist then
  raise notice 'not dropping role client -- objects in another databases rely on it';
end
$$;

drop schema lookup cascade;

drop domain phone_number;
