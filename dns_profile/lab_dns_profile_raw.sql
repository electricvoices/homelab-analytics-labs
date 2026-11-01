-- lab_dns_profile data validation

-- One row = one hour + status pair | BROKEN
-- Period: 2026-10-14 00:00 to 2026-10-20 23:00 (168 hours) | BROKEN
\echo "Total number of rows: 842 | 168 hours * 5 rows per hour = 840 | 2 EXTRA ROWS"
SELECT COUNT(*) FROM lab_dns_profile_raw;

-- Every hour in the period appears | BROKEN
\echo "168 hours should be accounted for throughout"
-- One row contains missing data ('2026-10-18 03:00:00')
WITH timeline AS (
    SELECT generate_series(
        '2026-10-14 00:00'::timestamp,
        '2026-10-20 23:00'::timestamp,
        '1 hour'::interval) AS expected_hour)
SELECT t.expected_hour, raw.hour_start,
    CASE
        WHEN raw.hour_start IS NULL THEN 'MISSING DATA'
        ELSE ((EXTRACT(EPOCH FROM t.expected_hour) - EXTRACT(EPOCH FROM raw.hour_start)) / 3600)::TEXT
    END AS status_or_changes
FROM timeline t
LEFT JOIN lab_dns_profile_raw raw
    ON t.expected_hour = raw.hour_start
WHERE raw.hour_start IS NULL
    OR t.expected_hour <> raw.hour_start
ORDER BY t.expected_hour;

-- Allowed statuses: CACHE, CACHE_STALE, FORWARDED, GRAVITY, REGEX (each hr should have all 5) | BROKEN
\echo "2026-10-16 14:00:00 has 10 entries while 1970-01-01 (likely the 2 extra rows from before) only have 2 matches"
SELECT DISTINCT(hour_start), COUNT(*) AS rows
FROM lab_dns_profile_raw
GROUP BY hour_start
HAVING COUNT(*) != 5;

-- Blocked statuses: GRAVITY & REGEX are blocks & nothing else is | BROKEN: 19 entries where not upper-case or has extra whitespace
\echo "1: several entries in query_status will mismatch not being case-sensitive ('CACHE' vs 'cache' or '  cache')"
SELECT DISTINCT(query_status), COUNT(*) AS count
FROM lab_dns_profile_raw
GROUP BY query_status;


-- Queries: INT from 0 to 10000 per status per hour | BROKEN
\echo "1 row w/1284733 queries"
SELECT * FROM lab_dns_profile_raw
WHERE queries NOT BETWEEN 0 AND 10000;


-- Every hour has exactly 5 rows | BROKEN ('2026-10-16 14:00:00 has 10 unique query_status items)
\echo "10 types indiciated from 2026-10-16 14:00:00 run"
SELECT hour_start, COUNT(query_status) AS types
FROM lab_dns_profile_raw
GROUP BY hour_start HAVING COUNT(DISTINCT(query_status)) > 5;


-- is_blocked is only true or false | BROKEN
\echo "14 rows return where is_blocked != 'true' or 'false'"
SELECT * FROM lab_dns_profile_raw
WHERE is_blocked NOT IN ('true', 'false')
    OR is_blocked IS NULL;


-- queries is never missing | BROKEN
\echo "2 records where queries IS NULL"
SELECT * FROM lab_dns_profile_raw
WHERE queries IS NULL;


-- Distinct (hour_start, UPPER(TRIM(query_status))) pairs
\echo "Total distinct (hour_start, query_status) pairs = 842"
SELECT COUNT(DISTINCT(hour_start, query_status)) AS count
FROM lab_dns_profile_raw;
\echo "Same query but applying trim for whitespace & UPPER formatting = 837"
SELECT COUNT(DISTINCT(hour_start, UPPER(TRIM(query_status)))) AS count
FROM lab_dns_profile_raw;
\echo "Every row from 2026-10-16 14:00 ordered by UPPER(TRIM(query_status)) = 10 results"
SELECT * FROM lab_dns_profile_raw
WHERE hour_start = '2026-10-16 14:00'
ORDER BY UPPER(TRIM(query_status));


-- Does is_blocked agree with itself?
\echo "8 different values for is_blocked group by count = 14 rows recorded"
\echo "('true', 'Y', '1', 'yes') -> 'true' & ('false', 'N', '0') -> false & blanks NULL"
\echo "0 mismatches for true/false when recoded with proper true/false booleans"
WITH recorded_values AS (
    SELECT hour_start, UPPER(TRIM(query_status)) AS status,
    CASE
        WHEN is_blocked IN ('true', 'Y', '1', 'yes') THEN true
        WHEN is_blocked IN ('false', 'N', '0') THEN false
    END AS blocked
    FROM lab_dns_profile_raw)
SELECT COUNT(*) AS mismatches
FROM recorded_values
WHERE (recorded_values.blocked = 'true' AND recorded_values.status NOT IN ('GRAVITY', 'REGEX'))
    OR (recorded_values.blocked = 'false' AND recorded_values.status IN ('GRAVITY', 'REGEX'));
