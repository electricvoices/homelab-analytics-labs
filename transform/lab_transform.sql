-- Lab #4: Build a Daily Summary Report


\echo "Step 1: derived fields per hour"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start)
SELECT hour_start,
    EXTRACT(HOUR FROM hour_start) AS hour,
    TO_CHAR(hour_start, 'Dy') AS weekday,
    EXTRACT(ISODOW FROM hour_start) IN (6, 7) AS is_weekend,
    total_queries, blocked_queries,
    ROUND(100.0 * blocked_queries / total_queries, 1) AS blocked_pct
FROM dns_hourly
WHERE hour_start < '2026-10-14 04:00'
ORDER BY hour_start;

\echo "Step 2: hour per traffic bin"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
binned AS (
    SELECT hour_start, total_queries,
        CASE
            WHEN total_queries < 1000 THEN '1 quiet'
            WHEN total_queries < 3000 THEN '2 normal'
            ELSE '3 busy'
        END AS traffic_bin
    FROM dns_hourly)
SELECT traffic_bin,
    COUNT(*) AS hours,
    MIN(total_queries) AS lowest,
    MAX(total_queries) AS highest
FROM binned
GROUP BY traffic_bin
ORDER BY traffic_bin;

\echo "Step 3: hours per quartile (equal-count bins)"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
ranked AS (
    SELECT hour_start, total_queries,
        NTILE(4) OVER (ORDER BY total_queries) AS quartiles
    FROM dns_hourly)
SELECT quartiles,
    COUNT(*) AS hours,
    MIN(total_queries) AS lowest,
    MAX(total_queries) AS highest
FROM ranked
GROUP BY quartiles
ORDER BY quartiles;

\echo "Step 4: roll up from hours to days"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
with_day AS (
    SELECT DATE_TRUNC('day', hour_start)::date AS day,
        total_queries, blocked_queries
    FROM dns_hourly)
SELECT day, TO_CHAR(day, 'Dy') AS weekday,
    COUNT(*) AS hours,
    SUM(total_queries) AS total_queries,
    SUM(blocked_queries) AS blocked_queries,
    ROUND(100.0 * SUM(blocked_queries) / SUM(total_queries), 1) AS pct_blocked
FROM with_day
GROUP BY day
ORDER BY day;

\echo "Step 5: pivot statuses into columns"
WITH with_day AS (
    SELECT DATE_TRUNC('day', hour_start)::date AS day,
        query_status,
        queries
    FROM lab_dns_profile_clean)
SELECT day,
    SUM(queries) FILTER (WHERE query_status = 'CACHE') AS cache,
    SUM(queries) FILTER (WHERE query_status = 'CACHE_STALE') AS cache_stale,
    SUM(queries) FILTER (WHERE query_status = 'FORWARDED') AS forwarded,
    SUM(queries) FILTER (WHERE query_status = 'GRAVITY') AS gravity,
    SUM(queries) FILTER (WHERE query_status = 'REGEX') AS regex,
    SUM(queries) AS total
FROM with_day
GROUP BY day
ORDER BY day;

\echo "Step 6: min-max scale the daily totals (0 = quietest, 1 = busiest)"
WITH with_day AS (
    SELECT DATE_TRUNC('day', hour_start)::date AS day,
        queries
    FROM lab_dns_profile_clean),
daily AS (
    SELECT day, SUM(queries) AS total_queries
    FROM with_day
    GROUP BY day)
SELECT day,
    total_queries,
    MIN(total_queries) OVER () AS week_min,
    MAX(total_queries) OVER () AS week_max,
    ROUND(1.0 * (total_queries - MIN(total_queries) OVER ())
        / (MAX(total_queries) OVER () - MIN(total_queries) OVER ()), 2) AS queries_scaled
FROM daily
ORDER BY day;

\echo "Step 7: Pi health per day"
WITH pi_by_hour AS (
    SELECT DISTINCT hour_start,
        DATE_TRUNC('day', hour_start)::date AS day,
        cpu_pct, temp_c
    FROM lab_pi_hourly_raw)
SELECT day, COUNT(*) AS pi_hours,
    ROUND(AVG(cpu_pct), 1) AS avg_cpu,
    MAX(temp_c) AS max_temp
    FROM pi_by_hour
    GROUP BY day
    ORDER BY day;

\echo "Step 8: build the final report table"
DROP TABLE IF EXISTS lab_daily_report;
CREATE TABLE lab_daily_report AS
WITH dns_hourly AS (
    SELECT hour_start,
        DATE_TRUNC('day', hour_start)::date AS day,
        SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
dns_daily AS (
    SELECT day,
        SUM(total_queries) AS total_queries,
        SUM(blocked_queries) AS blocked_queries,
        COUNT(*) FILTER (WHERE total_queries >= 3000) AS busy_hours
    FROM dns_hourly
    GROUP BY day),
pi_by_hour AS (
    SELECT DISTINCT hour_start,
        DATE_TRUNC('day', hour_start)::date AS day,
        cpu_pct,
        temp_c
    FROM lab_pi_hourly_raw),
pi_daily AS (
    SELECT day,
        COUNT(*) AS pi_hours,
        ROUND(AVG(cpu_pct), 1) AS avg_cpu,
        MAX(temp_c) AS max_temp
    FROM pi_by_hour
    GROUP BY day)
SELECT d.day,
    TO_CHAR(d.day, 'Dy') AS weekday,
    d.total_queries,
    d.blocked_queries,
    ROUND(100.0 * d.blocked_queries / d.total_queries, 1) AS blocked_pct,
    d.busy_hours,
    p.pi_hours,
    p.avg_cpu,
    p.max_temp
FROM dns_daily d
LEFT JOIN pi_daily p ON p.day = d.day
ORDER BY d.day;

\echo "Step 8b: governance - access and data dictionary"
GRANT SELECT ON lab_daily_report TO dashboard_reader;
COMMENT ON TABLE lab_daily_report IS 'Daily DNS + Pi health summary, Oct 14-20 2026. Source: lab_dns_profile_clean + lab_pi_hourly_raw. Built by lab_transform.sql Step 8.';
COMMENT ON COLUMN lab_daily_report.blocked_pct IS 'Share of queries blocked (GRAVITY + REGEX), in %. A ratio: never SUM or AVG it; recalculate from blocked_queries / total_queries.';
COMMENT ON COLUMN lab_daily_report.busy_hours IS 'Hours that day with 3,000+ total queries. A count: safe to SUM.';
COMMENT ON COLUMN lab_daily_report.pi_hours IS 'Hours of Pi health data that day (coverage). Below 24 means avg_cpu and max_temp cover a partial day (10-17 = 21).';

SELECT * FROM lab_daily_report ORDER BY day;
