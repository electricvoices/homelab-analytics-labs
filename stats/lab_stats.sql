\echo "Step 2a: center, spread and IQR (from Step 1) for hourly DNS totals"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
stats AS (
    SELECT ROUND(AVG(total_queries)) AS mean,
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY total_queries) AS q1,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_queries) AS median,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_queries) AS q3
    FROM dns_hourly)
SELECT mean, median, q1, q3,
    q3 - q1 AS iqr,
    q1 - 1.5 * (q3 - q1) AS lower_fence,
    q3 + 1.5 * (q3 - q1) AS upper_fence
FROM stats;

\echo "Step 2b: hours outside the IQR fences"
WITH dns_hourly AS (
    SELECT hour_start, SUM(queries) AS total_queries
    FROM lab_dns_profile_clean
    GROUP BY hour_start),
stats AS (
    SELECT
        PERCENTILE_CONT(0.25) WITHIN GROUP (ORDER BY total_queries) AS q1,
        PERCENTILE_CONT(0.75) WITHIN GROUP (ORDER BY total_queries) AS q3
    FROM dns_hourly)
SELECT h.hour_start, h.total_queries
FROM dns_hourly h
CROSS JOIN stats s
WHERE h.total_queries > s.q3 + 1.5 * (s.q3 - s.q1)
    OR h.total_queries < s.q1 - 1.5 * (s.q3 - s.q1)
ORDER BY h.total_queries DESC;

\echo "Step 3: 3-day moving averages"
SELECT day, weekday, total_queries,
    ROUND(AVG(total_queries) OVER
        (ORDER BY day ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS queries_3day_avg,
    avg_cpu,
    ROUND(AVG(avg_cpu) OVER
        (ORDER BY day ROWS BETWEEN 2 PRECEDING AND CURRENT ROW), 1) AS cpu_3day_avg
FROM lab_daily_report
ORDER BY day;

\echo "Step 4: day-over-day change"
SELECT day, weekday, total_queries,
    LAG(total_queries) OVER (ORDER BY day) AS prev_day,
    ROUND(100.0 * (total_queries - LAG(total_queries) OVER (ORDER BY day))
        / LAG(total_queries) OVER (ORDER BY day), 1) AS pct_change
FROM lab_daily_report
ORDER BY day;

\echo "Step 5a: CPU before vs after the Netdata removal (10-18 19:17)"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct
    FROM lab_pi_hourly_raw
    WHERE hour_start >= '2026-10-14'),
grouped AS (
    SELECT CASE WHEN hour_start >= '2026-10-18 20:00' THEN 'after' ELSE 'before'
        END AS period,
        cpu_pct
    FROM pi)
SELECT period, COUNT(*) AS hours,
    ROUND(AVG(cpu_pct), 2) AS mean_cpu,
    ROUND(STDDEV(cpu_pct), 2) AS sd_cpu
FROM grouped
GROUP BY period
ORDER BY period DESC;

\echo "Step 5b: t-test, CPU before vs after the Netdata removal"
WITH pi AS (
    SELECT DISTINCT hour_start, cpu_pct
    FROM lab_pi_hourly_raw
    WHERE hour_start >= '2026-10-14'),
grouped AS (
    SELECT CASE
            WHEN hour_start >= '2026-10-18 20:00' THEN 'after' ELSE 'before'
            END AS period,
        cpu_pct
    FROM pi),
s AS (
    SELECT COUNT(*) FILTER (WHERE period = 'before') AS n_before,
        AVG(cpu_pct) FILTER (WHERE period = 'before') AS mean_before,
        STDDEV(cpu_pct) FILTER (WHERE period = 'before') AS sd_before,
        COUNT(*) FILTER (WHERE period = 'after') AS n_after,
        AVG(cpu_pct) FILTER (WHERE period = 'after') AS mean_after,
        STDDEV(cpu_pct) FILTER (WHERE period = 'after') AS sd_after
    FROM grouped)
SELECT ROUND(mean_before - mean_after, 2) AS difference,
    ROUND(SQRT(sd_before * sd_before / n_before + sd_after * sd_after / n_after), 3) AS std_error,
    ROUND((mean_before - mean_after) / SQRT(sd_before * sd_before / n_before
        + sd_after * sd_after / n_after), 1) AS t
FROM s;
