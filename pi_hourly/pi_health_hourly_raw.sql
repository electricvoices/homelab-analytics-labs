\echo "Step 1: load the Pi health data"
SELECT COUNT(*) AS total_rows,
    COUNT(DISTINCT hour_start) AS distinct_hours,
    MIN(hour_start) AS first_hour,
    MAX(hour_start) AS last_hour
FROM lab_pi_hourly_raw;

\echo "Step 2: check what one row means in each table"
SELECT COUNT(*) AS total_rows,
    COUNT(DISTINCT hour_start) AS distinct_hours,
    MIN(hour_start) AS first_hour,
    MAX(hour_start) AS last_hour
FROM lab_dns_profile_clean;

\echo "Step 3: look at the Pi duplicates"
SELECT * FROM lab_pi_hourly_raw
WHERE hour_start IN (
    SELECT hour_start
    FROM lab_pi_hourly_raw
    GROUP BY hour_start
    HAVING COUNT(*) > 1)
ORDER BY hour_start;

\echo "Step 4: both sides at one row per hour"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct, mem_pct, temp_c
    FROM lab_pi_hourly_raw),
dns_hourly AS (
    SELECT hour_start,
        SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start)
SELECT (SELECT COUNT(*) FROM pi) AS pi_rows,
    (SELECT COUNT(DISTINCT hour_start) FROM pi) AS pi_hours,
    (SELECT COUNT(*) FROM dns_hourly) AS dns_rows;

\echo "Step 5: row counts for each join type"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct, mem_pct, temp_c
    FROM lab_pi_hourly_raw),
dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start)
SELECT
    (SELECT COUNT(*) FROM dns_hourly d
        JOIN pi p ON p.hour_start = d.Hour_start) AS inner_rows,
    (SELECT COUNT(*) FROM dns_hourly d
        LEFT JOIN pi p ON p.hour_start = d.hour_start) AS left_rows,
    (SELECT COUNT(*) FROM dns_hourly d
        LEFT JOIN pi p ON p.hour_start = d.hour_start
        WHERE p.hour_start IS NULL) AS dns_hrs_without_pi,
    (SELECT COUNT(*) FROM dns_hourly d
        FULL JOIN pi p ON p.hour_start = d.hour_start) AS full_rows;

\echo "Step 6: CPU in quiet vs busy DNS hours"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct, mem_pct, temp_c
    FROM lab_pi_hourly_raw),
dns_hourly AS (
    SELECT hour_start,
        SUM(queries) AS total_queries,
        SUM(queries) FILTER (WHERE is_blocked) AS blocked_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
joined AS (
    SELECT d.hour_start, d.total_queries, p.cpu_pct,
        NTILE(2) OVER (ORDER BY d.total_queries) AS half
    FROM dns_hourly d
    JOIN pi p ON p.hour_start = d.hour_start)
SELECT CASE half WHEN 1 THEN 'quiet' ELSE 'busy' END AS dns_level,
    COUNT(*) AS hours,
    ROUND(AVG(total_queries)) AS avg_queries,
    ROUND(AVG(cpu_pct), 1) AS avg_cpu
FROM joined GROUP BY half ORDER BY half;

\echo "Step 7: correlation between DNS traffic and CPU"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct, mem_pct, temp_c
    FROM lab_pi_hourly_raw),
dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start)
SELECT ROUND(CORR(d.total_queries, p.cpu_pct)::numeric, 2) AS corr_queries_cpu,
    ROUND(CORR(d.total_queries, p.temp_c)::numeric, 2)  AS corr_queries_temp
FROM dns_hourly d
JOIN pi p ON p.hour_start = d.hour_start;

