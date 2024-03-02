**Enhancing Switchboard with Timescale DB**

[TOC]

# Motivation

With a write (specifically insert) heavy workflow that can be time-partitioned, [TimescaleDB offers significant single row insert performance improvements.](https://blog.timescale.com/blog/timescaledb-vs-6a696248104e/)

The main reason for this can be found in TimescaleDB's docs:

> **Summary**
> Whenever a new row of data is inserted into PostgreSQL, the database needs to update the indexes (e.g., B-trees) for each of the table’s indexed columns. Once the indexes are too large to fit in memory — which we find typically happens when your table is in the 10s of millions of rows, depending on your allocated memory — this requires swapping one or more pages in from disk. It is this disk swapping that creates the insert bottleneck. Throwing more memory at the problem only delays the inevitable.
>
> TimescaleDB solves this through its heavily utilization and automation of [time-space partitioning](https://blog.timescale.com/time-series-data-why-and-how-to-use-a-relational-database-instead-of-nosql-d0cd6975e87c/), even when running on a single machine. Essentially, all writes to recent time intervals are only to tables that remain in memory. This results in a consistent 20x insert performance improvement over PostgreSQL when inserting data at scale.

We're not sure what throughput Switchboard will need to support in the future, but if we need to support 10+ million writes per day, this will become an absolute requirement to avoid the type of performance degradation we saw with Switchboard, as we never once again reached the peak performance we saw during Bernie of 200-300 per second.

# Choosing a Chunk Size

One of the key questions in TimescaleDB design is the `chunk_time_interval` - this is the parameter used to determine the underlying partition size.

From the docs:

> The key property of choosing the time interval is that the chunk (including indexes) belonging to the most recent interval (or chunks if using space partitions) fit into memory. As such, we typically recommend setting the interval so that these chunk(s) comprise no more than 25% of main memory.
>
> > **TIP:**Make sure that you are planning for recent chunks from _all_ active hypertables to fit into 25% of main memory, rather than 25% per hypertable.
> >
> > > **TIP:**One caveat is that the total chunk size is actually dependent on both the underlying data size _and_ any indexes, so some care might be taken if you make heavy use of expensive index types (e.g., some PostGIS geospatial indexes). During testing, you might check your total chunk sizes via the [`chunks_detailed_size`](https://docs.timescale.com/latest/api#chunks_detailed_size) function.

The other consideration is how many partitions we need to check in order to satisfy a given query.

For example, checking to find a previous mapping (which was previously just a quick index lookup) now is a quick index lookup on many tables. Although checking 7 tables (for the previous 7 days, for example) should still be quick, that's a reason not to make it something like every hour.

For us, I think 1 day is a good interval, but this can also be changed in response to increased volume if we need to change it, and the change will affect future partition creation.

# The DDL

The DDL of actually creating the hyper tables is pretty simple.

First, we need to drop foreign keys pointing at `sms.outbound_messages`:

```sql
alter table sms.delivery_reports drop constraint delivery_reports_message_id_fkey;
```

The `routing` and `telco` tables actually don't have foreign keys, interestingly enough.

Second, we need to add additional columns to `routing` and `telco` to support joins back to the core message table with the partition key.

```sql
alter table sms.outbound_messages_routing add column original_created_at timestamp;
alter table sms.outbound_messages_telco add column original_created_at timestamp;
```

Then, we need to drop primary keys on the soon to be hyper tables, as those will need time included in their primary keys:

```sql
alter table sms.outbound_messages drop constraint outbound_messages_pkey;
-- ditto for routing, telco
```

We can drop any additional indexes on `timestamp`, as those will be covered by the new primary key.

Now, we're ready to do the hyper table creation:

```sql
select create_hypertable(
  'sms.outbound_messages',
  'created_at',
  chunk_time_interval => interval '1 day',
  migrate_data => true
);
-- ditto for telco on `original_created_at`
-- routing is handled separately (see below)
```

Because we've supplied `migrate_data => true`, this will take some time to actually move the data into the proper chunks.

`routing` should be partitioned based on `original_created_at` as well because having all 3 message tables share the same partition key will ensure joins are the fastest.

However, down the line, we could consider using `processed_at` (routing's insert time) as the partition key because of the overloaded check query:

```sql
  select phone_number
  from sms.fresh_phone_commitments
  where sending_location_id = ANY(sending_location_id_options)
    and commitment <= 200
    and phone_number not in (
      select from_number
      from sms.outbound_messages_routing
      where processed_at > now() - interval '1 minute'
        and stage <> 'awaiting-number'
        and is_current_period = true
      group by sms.outbound_messages_routing.from_number
      having sum(estimated_segments) > 6
    )
```

TimescaleDB will be able to additional optimize this query because of the way it hashes time buckets, even if they all fall within 1 partition by day.

In order to make this efficient, we'll also need to store `processed_at` on the main messages table and the `telco` table so that we can keep joins fast.

## Other Tables

Although not critical, we _might as well_ also partition `sms.inbound_messages`, `sms.delivery_reports`, and even `sms.inbound_message_forward_attempts` and `sms.delivery_report_forward_attempts` as well. These are also simple `create_hypertable` with `migrate_data => true` statements.

# Required Changes

All required changes flow from one basic constraint - when your table is partitioned, your query should also include the partition key.

## All Queries/Joins Need Time

### Queries

To find the list of queries that need to be changed, you can just do a CMD + F and search for `from sms.outbound_messages`.

Each query will need to query by time, and that additionally means the `created_at` of `sms.outbound_messages` will need to be passed around each job, alongside the message id, because the timestamp is now part of the identifier.

### Delivery Report Resolution

Delivery report resolution current joins by `message_service_id`:

```sql
  update sms.delivery_reports
  set message_id = sms.outbound_messages_telco.id
  from sms.outbound_messages_telco
  where sms.delivery_reports.message_service_id = sms.outbound_messages_telco.service_id
    and sms.delivery_reports.message_id is null
    and sms.delivery_reports.created_at >= fire_date - as_far_back_as
    and sms.delivery_reports.created_at <= fire_date - as_recent_as
```

This is a join to the `telco` table without a known timestamp. To remedy this, we can just add a pretty loose timestamp constraint:

```sql
  update sms.delivery_reports
  set message_id = sms.outbound_messages_telco.id
  from sms.outbound_messages_telco
  where sms.delivery_reports.message_service_id = sms.outbound_messages_telco.service_id
    and sms.delivery_reports.message_id is null
    and sms.delivery_reports.created_at >= fire_date - as_far_back_as
    and sms.delivery_reports.created_at <= fire_date - as_recent_as
    and sms.outbound_messages_telco > date_trunc('day', now() at time zone 'America/New_York');
```

And create a new special function for historical backfilling that has different, or looser, time constraints.

# Optional Changes

## Use Continuous Aggregates instead of Cache Tables

Our use of `fresh_phone_commitments` could be deprecated in favor of:

```sql
create materialized view sms.fresh_phone_commitments
	with ( timescaledb.continuous ) as
	select count(*), time_bucket()
	...

SELECT add_continuous_aggregate_policy('sms.fresh_phone_commitments',
    start_offset => NULL,
    end_offset => INTERVAL '15 minutes',
    schedule_interval => INTERVAL '15 minutes');
```

This would refresh `fresh_phone_commitments` every 15 minutes, but the magic of the continuous aggregates' [real-time aggregation](https://docs.timescale.com/latest/using-timescaledb/continuous-aggregates#real-time-aggregates) functionality is that Timescale will combine the data that has been aggregated with the data that hasn't been, producing an accurate result even though data has been inserted since the last refresh:

> A query on a continuous aggregate will, by default, use real-time aggregation ... to combine materialized aggregates with recent data from the source hypertable. By combining raw and materialized data in this way, real-time aggregation produces accurate and up-to-date results while still benefiting from pre-computed aggregates for a large portion of the result.

One caveat is that this might actually break (produce inaccurate results) if we update a record in a time bucket that has already been aggregated. This should be tested before further pursuing this strategy, since our delayed phone number purchasing pathway involves these types of updates.

# Migration

## Inline?

Assuming we're already on Zalando / a PostgreSQL installation with TimescaleDB enabled, TimescaleDB has the option to migrate the data to the chunked setup when using `create_hypertable`. I think we can probably just use this and run standard migrations during off hours. If it runs on the Thanksgiving switchboard instance ONLY, it should be fast enough.

# Questions

## Additional Partitioning Column - profile_id?

TimescaleDB supports an additional partition column, called "Space partitions". Although discourages using them because they can result in too many partitions, which complicates query planning.

> **TIP:**TimescaleDB does _not_ benefit from a very large number of space partitions (such as the number of unique items you expect in partition field). A very large number of such partitions leads both to poorer per-partition load balancing (the mapping of items to partitions using hashing), as well as increased planning latency for some types of queries. We recommend tying the number of space partitions to the number of disks and/or data nodes.

That being said, the option to move a client's data to their own partition (and even to their own tablespace and disk) might prove really helpful if a client significantly ramps up their volume.

To do this, we could additional partition on `profile_id`, but specify a custom hash function for `profile_id`, `(profile_id) => 1`(all profiles to one partition.)

Then, to place just a larger client on the own partition, we could just redefine that function:

`(profile_id) => profile_id == specific_client_id ? 2 : 1`.

I think we don't need to do this - at least initially. Before we do, we should look into the behavior of updating the custom partition function (is any data migration required?).

## Retention Policy

We can use TimescaleDB's retention policies to delete old messages, delivery reports, and routing entries automatically.

Because of their partitioning setup,

```sql
SELECT drop_chunks('conditions', INTERVAL '24 hours');
```

From the docs:

> This will drop all chunks from the hypertable `conditions` that _only_ include data older than this duration, and will _not_ delete any individual rows of data in chunks.

Is basically instant and doesn't require reconstructing a bunch of indexes like a normal delete does.

It can be auto-scheduled via:

```sql
SELECT add_retention_policy('conditions', INTERVAL '24 hours');
```

For us, something like `3 months` is probably good. It's pretty large, but coupled with an archival job, it'll help us keep our disk costs down.

## Time for a Separate prev_mapping table?

A separate `prev_mapping` table might become necessary.

The `prev_mapping` check looks like:

```sql
  -- Check for majority case of a repeat message, getting v_sending_location_id and from_number, insert and return
  select from_number, created_at, sending_location_id
  from sms.outbound_messages_routing
  where to_number = message.to_number
    and sending_location_id in (
      select id
      from sms.sending_locations
      where sms.sending_locations.profile_id = message.profile_id
    )
    and exists (
      select 1
      from sms.phone_numbers
      where sms.phone_numbers.sending_location_id = sms.outbound_messages_routing.sending_location_id
        and sms.phone_numbers.phone_number = sms.outbound_messages_routing.from_number
        and (
          sms.phone_numbers.cordoned_at is null
          or
          sms.phone_numbers.cordoned_at > now() - interval '3 days'
        )
    )
    and (prev_mapping_validity_interval is null or created_at > now() - prev_mapping_validity_interval)
  order by created_at desc
  limit 1
  into v_prev_mapping_from_number, v_prev_mapping_created_at, v_sending_location_id;
```

And involves checking all chunks since the `prev_mapping_validity_interval`, which will probably always be at least 1 week. This check is the only place we currently query `sms.outbound_messages` older than 1 day (the chunk size). A quick index check on the 7 chunks comprising 1-week mapping interval will be fast. However, if we don't query chunks older than 1 day at all PostgreSQL will be able to decide to not keep this table's data in memory at all, improving memory utilization for the rest of our queries.

A prev_mapping table requires:

- A trigger on `sms.outbound_messages_routing` that upserts into `prev_mapping` with the `(profile_id, to_number, from_number, sending_location_id)`.
- A trigger on `sms.phone_numbers` that deletes the `prev_mapping` (or marks it as invalidates) when the number is sold or 3 days after it's cordoned.

If the prev_mapping table becomes very large (more than 100 million rows), we should consider partitioning it by `(profile_id)`, or `(profile_id, to_number)`.
