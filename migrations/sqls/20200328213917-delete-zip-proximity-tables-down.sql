create table geo.zip_proximity (
  zip1 zip_code not null,
  zip1_state us_state not null,
  zip2 zip_code not null,
  zip2_state us_state not null,
  distance_in_miles decimal not null
);

comment on table geo.zip_proximity is E'@omit';

create index zip_proximity_idx on geo.zip_proximity (zip1, zip2_state, zip2, zip2_state, distance_in_miles desc);
