-- query for org_mozilla_fenix_glam_release__clients_histogram_aggregates_v1;
CREATE TEMP FUNCTION udf_merged_user_data(aggs ANY TYPE)
RETURNS ARRAY<
  STRUCT<
    latest_version INT64,
    metric STRING,
    metric_type STRING,
    key STRING,
    agg_type STRING,
    value ARRAY<STRUCT<key STRING, value INT64>>
  >
> AS (
  (
    WITH unnested AS (
      SELECT
        *
      FROM
        UNNEST(aggs)
    ),
    aggregated_data AS (
      SELECT AS STRUCT
        latest_version,
        metric,
        metric_type,
        key,
        agg_type,
        `moz-fx-data-shared-prod`.udf.map_sum(ARRAY_CONCAT_AGG(value)) AS value
      FROM
        unnested
      GROUP BY
        latest_version,
        latest_version,
        metric,
        metric_type,
        key,
        agg_type
    )
    SELECT
      ARRAY_AGG((latest_version, metric, metric_type, key, agg_type, value))
    FROM
      aggregated_data
  )
);

WITH extracted_accumulated AS (
  SELECT
    *
  FROM
    glam_etl.org_mozilla_fenix_glam_release__clients_histogram_aggregates_v1
  WHERE
    sample_id >= @min_sample_id
    AND sample_id <= @max_sample_id
),
filtered_accumulated AS (
  SELECT
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel,
    histogram_aggregates
  FROM
    extracted_accumulated
  LEFT JOIN
    glam_etl.org_mozilla_fenix_glam_release__latest_versions_v1
  USING
    (channel)
  WHERE
      -- allow for builds to be slighly ahead of the current submission date, to
      -- account for a reasonable amount of clock skew
    `moz-fx-data-shared-prod`.udf.fenix_build_to_datetime(app_build_id) < DATE_ADD(
      @submission_date,
      INTERVAL 3 day
    )
      -- only keep builds from the last year
    AND `moz-fx-data-shared-prod`.udf.fenix_build_to_datetime(app_build_id) > DATE_SUB(
      @submission_date,
      INTERVAL 365 day
    )
    AND app_version >= (latest_version - 2)
),
-- unnest the daily data
extracted_daily AS (
  SELECT
    * EXCEPT (app_version, histogram_aggregates),
    CAST(app_version AS INT64) AS app_version,
    unnested_histogram_aggregates AS histogram_aggregates
  FROM
    glam_etl.org_mozilla_fenix_glam_release__view_clients_daily_histogram_aggregates_v1,
    UNNEST(histogram_aggregates) unnested_histogram_aggregates
  WHERE
    submission_date = @submission_date
    AND value IS NOT NULL
    AND ARRAY_LENGTH(value) > 0
),
filtered_daily AS (
  SELECT
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel,
    latest_version,
    histogram_aggregates.*
  FROM
    extracted_daily
  LEFT JOIN
    glam_etl.org_mozilla_fenix_glam_release__latest_versions_v1
  USING
    (channel)
  WHERE
      -- allow for builds to be slighly ahead of the current submission date, to
      -- account for a reasonable amount of clock skew
    `moz-fx-data-shared-prod`.udf.fenix_build_to_datetime(app_build_id) < DATE_ADD(
      @submission_date,
      INTERVAL 3 day
    )
      -- only keep builds from the last year
    AND `moz-fx-data-shared-prod`.udf.fenix_build_to_datetime(app_build_id) > DATE_SUB(
      @submission_date,
      INTERVAL 365 day
    )
    AND app_version >= (latest_version - 2)
),
-- re-aggregate based on the latest version
aggregated_daily AS (
  SELECT
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel,
    latest_version,
    metric,
    metric_type,
    key,
    agg_type,
    `moz-fx-data-shared-prod`.udf.map_sum(ARRAY_CONCAT_AGG(value)) AS value
  FROM
    filtered_daily
  GROUP BY
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel,
    latest_version,
    metric,
    metric_type,
    key,
    agg_type
),
-- note: this seems costly, if it's just going to be unnested again
transformed_daily AS (
  SELECT
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel,
    ARRAY_AGG(
      STRUCT<
        latest_version INT64,
        metric STRING,
        metric_type STRING,
        key STRING,
        agg_type STRING,
        aggregates ARRAY<STRUCT<key STRING, value INT64>>
      >(latest_version, metric, metric_type, key, agg_type, value)
    ) AS histogram_aggregates
  FROM
    aggregated_daily
  GROUP BY
    sample_id,
    client_id,
    ping_type,
    os,
    app_version,
    app_build_id,
    channel
)
SELECT
  COALESCE(accumulated.sample_id, daily.sample_id) AS sample_id,
  COALESCE(accumulated.client_id, daily.client_id) AS client_id,
  COALESCE(accumulated.ping_type, daily.ping_type) AS ping_type,
  COALESCE(accumulated.os, daily.os) AS os,
  COALESCE(accumulated.app_version, daily.app_version) AS app_version,
  COALESCE(accumulated.app_build_id, daily.app_build_id) AS app_build_id,
  COALESCE(accumulated.channel, daily.channel) AS channel,
  udf_merged_user_data(
    ARRAY_CONCAT(accumulated.histogram_aggregates, daily.histogram_aggregates)
  ) AS histogram_aggregates
FROM
  filtered_accumulated AS accumulated
FULL OUTER JOIN
  transformed_daily AS daily
USING
  (sample_id, client_id, ping_type, os, app_version, app_build_id, channel)
