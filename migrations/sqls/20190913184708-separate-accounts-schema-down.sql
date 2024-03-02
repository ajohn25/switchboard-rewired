alter table billing.clients set schema lookup;
alter function billing.current_client_id() set schema lookup;

drop schema billing cascade;
