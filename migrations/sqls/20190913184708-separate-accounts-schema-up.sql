create schema billing;
alter table lookup.clients set schema billing;
alter function lookup.current_client_id() set schema billing;

grant execute on function billing.current_client_id() to client;
grant usage on schema billing to client;
