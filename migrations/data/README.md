# Constructing the Seeds

`geo-seed.sql` was constructed by loading the data in and runnig `pg_dump`. This file contains instructions for performing that if it ever needs to be redone in the future.

## Setup

Open a `psql` session on any database (does not need to be production) and run:

```sql
create schema tmp;
```

## `geo.zip_area_codes`

`geo.zip_area_codes` contains zip code <-> area code pairings. The [Standard Area Code Database](https://www.area-codes.com/area-code-database.asp) from area-codes.com is used to seed this.

_Note: the +1 country code includes more than just the US. As such, the standard area code database includes area codes without US zip codes, hence why we filter out records with null zip codes. See [North American Area Codes](https://www.twilio.com/docs/glossary/north-american-area-codes)._

Select only the columns we are interested in:

```sh
xsv select ZipCode,NPA /path/to/zip-code-area-codes.csv > /path/to/zip-area-code.csv
```

```sql
create table tmp.zip_code_area_codes (
  zip text,
  area_code text
);

\copy tmp.zip_code_area_codes from '/path/to/zip-area-code.csv' with csv header;

insert into geo.zip_area_codes (zip, area_code)
select zip, area_code
from tmp.zip_code_area_codes
where zipcode is not null;
```

## `geo.zip_locations`

`geo.zip_locations` contains information about the location of each zip code. This is used with a Postgres geospatial query to find zip codes near each other. The [Pro set](https://simplemaps.com/data/us-zips) from simplemaps.com was used.

Select only the columns we are interested in:

```sh
xsv select zip,lat,lng,state_id /path/to/uszips.csv > /path/to/zip-locations.csv
```

Load the data:

```sql
create table tmp.zip_locations (
  zip text,
  lat numeric,
  lng numeric,
  state_id text
);

\copy tmp.zip_locations from '/path/to/zip-locations.csv' with csv header;

insert into geo.zip_locations (zip, state, location)
select
  zip,
  state_id as state,
  point ( lat, lng )
from tmp.zip_locations
where not lat is null
  and not lng is null;
```

## `geo.zip_proximity` (deprecated)

`geo.zip_proximity` contains distance mappings between every possible zip code pairing in the US. This was previously used to find zip codes near each other but has been replaced by `geo.zip_locations`. It may still be useful as a fallback in case `uszips.csv` is missing any records.

The National Bureau of Economic research publishes this [ZIP Code Distance Database](https://data.nber.org/data/zip-code-distance-database.html).

```sql
create table tmp.zip_proximity (
  zip1 text,
  zip2 text,
  distance decimal
);

\copy tmp.zip_proximity from '/path/to/zip-proximity.csv' with csv header;

-- Bring together zip code distance data with zip code state data
insert into geo.zip_promixity (zip1, zip1_state, zip2, zip2_state, distance_in_miles)
select
  tmp.zip_proximity.zip1,
  zip1_state.state as zip1_state,
  tmp.zip_proximity.zip2,
  zip2_state.state as zip2_state,
  tmp.zip_proximity.distance as distinace_in_miles
from tmp.zip_proximity
join tmp.zip_locations as zip1_state on zip1_state.zip = zip1
join tmp.zip_locations as zip2_state on zip2_state.zip = zip2;
```

## Generate Dump

Now, `geo.zip_area_codes`, `geo.zip_locations`, and (optionally) `geo.zip_proximity` are fully loaded.

Since we only want the data, not the migrations, we run

```sh
pg_dump "$DATABASE_URL" -a -n geo
```

## Clean Up

```sql
drop schema tmp cascade;
```
