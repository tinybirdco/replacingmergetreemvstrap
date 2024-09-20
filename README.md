# MVs over RMT do not work as you'd expect

[meme](https://imgflip.com/i/943xux)

## Problem description

We have this initial data with a video id, its channel, ts, and total views. We want to show always the latest value.
Besides we want an aggregation of views per channel, and we know Materialized Views in ClickHouse/Tinybird are awesome for that.

So, let's start.

## Latest value -> ReplacingMergeTree

```csv
video_id,channel,timestamp,views
koLTjbEco7Q,VercelHQ,2024-09-20 00:00:00,100
oZLjfTi2Y9w,VercelHQ,2024-09-20 00:00:00,200
IbX4W1aZjwk,itnig,2024-09-20 00:00:00,100
SyeksvGi4U0,itnig,2024-09-20 00:00:00,200
stQ10PwdiMA,tinybirdco,2024-09-20 00:00:00,100
F-M5VII4RGc,tinybirdco,2024-09-20 00:00:00,200
```

The data we receive is not incremental, we just want the latest update, so next hour when we'll receive an update on a video, we want to use that

```csv
video_id,channel,timestamp,views
F-M5VII4RGc,tinybirdco,2024-09-20 01:00:00,250
```

That's why we use a ReplacingMergeTree, that in the background merges the duplicates, and when queried with `FINAL` it returns the latest state.

```sql
SCHEMA >
    `video_id` String,
    `channel` LowCardinality(String),
    `timestamp` DateTime,
    `views` Int16

ENGINE "ReplacingMergeTree"
ENGINE_SORTING_KEY "channel,video_id"
ENGINE_VER "timestamp"
```

More details on deduplication at the [Deduplication Strategies guide](https://www.tinybird.co/docs/guides/querying-data/deduplication-strategies)

## Aggregation of channel totals -> MV with AggregatingMergeTree

We want the total of views per channel, so we create a MV:

```sql
    SELECT
        channel,
        sumState(views) AS total_views
    FROM yt_views
    GROUP BY channel

TYPE materialized
DATASOURCE channel_views_mv
```

```sql
SCHEMA >
    `channel` LowCardinality(String),
    `total_views` AggregateFunction(sum, Int16)

ENGINE "AggregatingMergeTree"
ENGINE_SORTING_KEY "channel"
```

That we will query like this:

```sql
    SELECT channel, sumMerge(total_views) views
    FROM channel_views_mv
    GROUP BY channel
```

Again, for more info about MVs, -State()... be sure to check the [docs](https://www.tinybird.co/docs/concepts/materialized-views).

If you read the title you already know it will not work as expected, but let's check:

## Demo script

Create a new Workspace, setup the CLI, and run `tb auth` for authentication. Then, run `./demoscript.sh`

```bash
tb push

tb datasource append yt_views first_views.csv

tb sql "SELECT * FROM yt_views FINAL"
# ----------------------------------------------------------
# | video_id    | channel    | timestamp           | views |
# ----------------------------------------------------------
# | koLTjbEco7Q | VercelHQ   | 2024-09-20 00:00:00 |   100 |
# | oZLjfTi2Y9w | VercelHQ   | 2024-09-20 00:00:00 |   200 |
# | IbX4W1aZjwk | itnig      | 2024-09-20 00:00:00 |   100 |
# | SyeksvGi4U0 | itnig      | 2024-09-20 00:00:00 |   200 |
# | F-M5VII4RGc | tinybirdco | 2024-09-20 00:00:00 |   200 |
# | stQ10PwdiMA | tinybirdco | 2024-09-20 00:00:00 |   100 |
# ----------------------------------------------------------
#
# all good, our rows are there

tb sql "SELECT channel, sum(views) AS total_views FROM yt_views FINAL GROUP BY channel ORDER BY channel"
#----------------------------
#| channel    | total_views |
#----------------------------
#| VercelHQ   |         300 |
#| itnig      |         300 |
#| tinybirdco |         300 |
#----------------------------
#
# totals look right

tb sql "SELECT channel, sumMerge(total_views) AS views FROM channel_views_mv GROUP BY channel ORDER BY channel"
#----------------------------
#| channel    | total_views |
#----------------------------
#| VercelHQ   |         300 |
#| itnig      |         300 |
#| tinybirdco |         300 |
#----------------------------
#
# good from MV as well, so where's the issue? On the new inserts:

tb datasource append yt_views second_views.csv
# we're updating it from 200 to 250 views, so we expect total to be 350 for tinybirdco channel

tb sql "SELECT * FROM yt_views FINAL"
# ----------------------------------------------------------
# | video_id    | channel    | timestamp           | views |
# ----------------------------------------------------------
# | koLTjbEco7Q | VercelHQ   | 2024-09-20 00:00:00 |   100 |
# | oZLjfTi2Y9w | VercelHQ   | 2024-09-20 00:00:00 |   200 |
# | IbX4W1aZjwk | itnig      | 2024-09-20 00:00:00 |   100 |
# | SyeksvGi4U0 | itnig      | 2024-09-20 00:00:00 |   200 |
# | stQ10PwdiMA | tinybirdco | 2024-09-20 00:00:00 |   100 |
# | F-M5VII4RGc | tinybirdco | 2024-09-20 01:00:00 |   250 |
# ----------------------------------------------------------
#
# all good, updated

tb sql "SELECT channel, sum(views) AS total_views FROM yt_views FINAL GROUP BY channel ORDER BY channel"
#----------------------------
#| channel    | total_views |
#----------------------------
#| VercelHQ   |         300 |
#| itnig      |         300 |
#| tinybirdco |         350 |
#----------------------------
#
# totals from yt_views FINAL is right

tb sql "SELECT channel, sumMerge(total_views) AS views FROM channel_views_mv GROUP BY channel ORDER BY channel"
#----------------------------
#| channel    | total_views |
#----------------------------
#| VercelHQ   |         300 |
#| itnig      |         300 |
#| tinybirdco |         550 |
#----------------------------
#
# !! 550 > 350 Now we see the discrepancy.
```

## Mental model

The key thing to understand here is that the MV is an insert trigger, it only "sees" the block of data that is processing at that time, so it does not know that there were already rows with the same Sorting Key that it needed to deduplicate.

## How do I handle this then?

Finding the best approach depends a lot on the use case, insert patterns, table sizes... and can involve adding at query time, using a lambda architecture, exploring VersionedCollapsingMergeTree... This [guide](https://www.tinybird.co/docs/guides/querying-data/lambda-architecture) is a nice starting point and, if you have doubts, feel free to contact us in our [Community Slack](https://www.tinybird.co/docs/community).