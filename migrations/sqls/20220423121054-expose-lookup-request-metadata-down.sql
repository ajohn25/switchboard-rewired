-- Revert view change
-- ----------------------------

drop view lookup.request_results;

create or replace view lookup.request_results as
  select
      accesses.request_id
    , accesses.phone_number
    , fresh_phone_data.phone_type
  from lookup.accesses
  join lookup.fresh_phone_data on fresh_phone_data.phone_number::text = accesses.phone_number::text
  where accesses.client_id = billing.current_client_id();

comment on view lookup.request_results is '
@foreignKey (request_id) references lookup.requests (id)
@primaryKey phone_number
';

grant select on table lookup.request_results to client;
