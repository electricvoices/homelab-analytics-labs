-- lab_dns_profile_clean
-- Builds a clean table from the raw database
\set ON_ERROR_STOP on

BEGIN;

\echo "Can be rerun as table will remove itself each run"
DROP TABLE IF EXISTS lab_dns_profile_clean;

\echo "Build the clean table for editing"
CREATE TABLE lab_dns_profile_clean AS
SELECT hour_start, query_status, is_blocked, queries
FROM lab_dns_profile_raw;

\echo "Updated query_status where all are UPPER(TRIM())"
UPDATE lab_dns_profile_clean SET query_status = UPPER(TRIM(query_status));

\echo "is_blocked becomes BOOLEAN & blanks still NULL for now"
ALTER TABLE lab_dns_profile_clean
ALTER COLUMN is_blocked TYPE BOOLEAN
USING CASE
    WHEN is_blocked IN ('true', 'Y', '1', 'yes') THEN true
    WHEN is_blocked IN ('false', 'N', '0', 'no') THEN false
END;


\echo "Remove the rows where dates are from 1970"
DELETE FROM lab_dns_profile_clean
WHERE hour_start < '2026-10-14 00:00:00';

\echo "Delete the duplicate rows from 2026-10-16 14:00:00"
DELETE FROM lab_dns_profile_clean
WHERE ctid NOT IN (
    SELECT MIN(ctid) FROM lab_dns_profile_clean
    GROUP BY hour_start, query_status, is_blocked, queries);

\echo "Check what the rules say about the empty values in is_blocked"
SELECT hour_start, query_status, is_blocked,
    query_status IN ('GRAVITY', 'REGEX') AS rule_says
FROM lab_dns_profile_clean
WHERE is_blocked IS NULL
ORDER BY hour_start;
\echo "Stage C: fill blank is_blocked from the status rule"
UPDATE lab_dns_profile_clean
SET is_blocked = query_status IN ('GRAVITY', 'REGEX')
WHERE is_blocked IS NULL;

-- Add the missing hour at @ 10-18-2026 03:00
\echo "Validate which should exist & compare against what does exist"
WITH timeline AS (
    SELECT generate_series(
        '2026-10-14 00:00'::timestamp,
        '2026-10-20 23:00'::timestamp,
        '1 hour'::interval) AS expected_hour),
statuses AS (
    SELECT DISTINCT query_status FROM lab_dns_profile_clean)
SELECT COUNT(*)
FROM timeline
CROSS JOIN statuses;
-- compare
WITH timeline AS (
    SELECT generate_series(
        '2026-10-14 00:00'::timestamp,
        '2026-10-20 23:00'::timestamp,
        '1 hour'::interval) AS expected_hour),
statuses AS (
    SELECT DISTINCT query_status FROM lab_dns_profile_clean)
SELECT t.expected_hour, s.query_status
FROM timeline t
CROSS JOIN statuses s
LEFT JOIN lab_dns_profile_clean c
    ON c.hour_start = t.expected_hour
    AND c.query_status = s.query_status
WHERE c.hour_start IS NULL
ORDER BY s.query_status;

-- insert the missing hour with queries NULL
\echo "insert missing hour of 10-18-2026 03:00 w/queries still NULL"
INSERT INTO lab_dns_profile_clean (hour_start, query_status, is_blocked, queries)
WITH timeline AS (
    SELECT generate_series(
        '2026-10-14 00:00'::timestamp,
        '2026-10-20 23:00'::timestamp,
        '1 hour'::interval) AS expected_hour),
statuses AS (
    SELECT DISTINCT query_status FROM lab_dns_profile_clean)
SELECT t.expected_hour, s.query_status,
    s.query_status IN ('GRAVITY', 'REGEX'), NULL
FROM timeline t
CROSS JOIN statuses s
LEFT JOIN lab_dns_profile_clean c
    ON c.hour_start = t.expected_hour
    AND c.query_status = s.query_status
WHERE c.hour_start IS NULL;

-- Bad values become NULL
\echo "Bad values to NULL - Verify"
SELECT hour_start, query_status, queries
FROM lab_dns_profile_clean
WHERE queries NOT BETWEEN 0 AND 10000;
\echo "Bad values to NULL - Commit"
UPDATE lab_dns_profile_clean
SET queries = NULL
WHERE queries NOT BETWEEN 0 AND 10000;
\echo "Flag the rows that will be estimates"
ALTER TABLE lab_dns_profile_clean
ADD COLUMN queries_imputed BOOLEAN NOT NULL DEFAULT false;
UPDATE lab_dns_profile_clean
SET queries_imputed = true
WHERE queries IS NULL;

-- Preview neighbor estimates for NULL values
\echo "Neighbor Estimates for values = NULL"
WITH estimates AS (
    SELECT hour_start, query_status, queries,
        LAG(queries) OVER by_status AS prev_hour,
        LEAD(queries) OVER by_status AS next_hour,
        ROUND((LAG(queries) OVER by_status + LEAD(queries) OVER by_status) / 2.0) AS estimate
    FROM lab_dns_profile_clean
    WINDOW by_status AS (PARTITION BY query_status ORDER BY hour_start))
SELECT hour_start, query_status, prev_hour, next_hour, estimate
FROM estimates
WHERE queries IS NULL
ORDER BY hour_start, query_status;
-- Write estimates into the table
\echo "Estimates for NULL values added"
WITH estimates AS (
    SELECT hour_start, query_status,
        ROUND((LAG(queries) OVER by_status + LEAD(queries) OVER by_status) / 2.0) AS estimate
    FROM lab_dns_profile_clean
    WINDOW by_status AS (PARTITION BY query_status ORDER BY hour_start))
UPDATE lab_dns_profile_clean c
SET queries = e.estimate
FROM estimates e
WHERE c.hour_start = e.hour_start
    AND c.query_status = e.query_status
    AND c.queries IS NULL;

-- =====================================================
-- CONSTRAINTS
-- =====================================================
\echo "Lock down the business rules"
ALTER TABLE lab_dns_profile_clean
    ALTER COLUMN hour_start SET NOT NULL,
    ALTER COLUMN query_status SET NOT NULL,
    ALTER COLUMN is_blocked SET NOT NULL,
    ALTER COLUMN queries SET NOT NULL,
    ADD CONSTRAINT dns_clean_one_row_per_pair UNIQUE (hour_start, query_status),
    ADD CONSTRAINT dns_clean_status_allowed CHECK (query_status IN ('CACHE', 'CACHE_STALE', 'FORWARDED', 'GRAVITY', 'REGEX')),
    ADD CONSTRAINT dns_clean_queries_range CHECK (queries BETWEEN 0 AND 10000),
    ADD CONSTRAINT dns_clean_blocked_rule CHECK (is_blocked = (query_status IN ('GRAVITY', 'REGEX')));

COMMIT;

-- ====================================================
-- VERIFY
-- ====================================================
\echo "Verified only 5 types of query_status all in UPPER(TRIM())"
SELECT query_status FROM lab_dns_profile_clean
GROUP BY query_status;

\echo "Verified is_blocked are BOOLEAN results w/some still NULL"
SELECT is_blocked FROM lab_dns_profile_clean
GROUP BY is_blocked;

\echo "Rows from 1970 are now gone"
SELECT MIN(hour_start) AS min_hour, MAX(hour_start) AS max_hour
FROM lab_dns_profile_clean;

\echo "Verify that the 5 extra duplicate rows from 2026-10-16 14:00:00 are gone"
SELECT * FROM lab_dns_profile_clean
WHERE hour_start = '2026-10-16 14:00:00'::timestamp
ORDER BY queries DESC;

\echo "1. 835 rows 2. 835 distinct (hour_start, query_status) pairs 3. 167 rows each status 4. 3 NULLs in is_blocked"
-- 1
SELECT COUNT(*) FROM lab_dns_profile_clean;
-- 2
SELECT COUNT(DISTINCT(hour_start, query_status)) FROM lab_dns_profile_clean;
-- 3
SELECT query_status, COUNT(hour_start) AS rows
FROM lab_dns_profile_clean
GROUP BY query_status;
-- 4 (0 NULLs expected)
SELECT * FROM lab_dns_profile_clean WHERE is_blocked IS NULL;

-- Ensure final count is what should be
\echo "Old Count: 842"
SELECT COUNT(*) FROM lab_dns_profile_raw;
\echo "New Count: 835"
SELECT COUNT(*) FROM lab_dns_profile_clean;
\echo "is_blocked column type should be boolean"
SELECT data_type FROM information_schema.columns
WHERE table_name = 'lab_dns_profile_clean' AND column_name = 'is_blocked';

-- is_blocked mismatches vs status rule (expect 0)
\echo "mismatches vs status rule"
SELECT COUNT(*) AS mismatches
FROM lab_dns_profile_clean
WHERE is_blocked <> (query_status IN ('GRAVITY', 'REGEX'));

-- check for null queries
SELECT COUNT(*) AS total_rows,
    COUNT(*) - COUNT(queries) AS invalid_queries
FROM lab_dns_profile_clean;

-- Check for 0 NULLs, 8 imputed, total 334457
SELECT COUNT(*) - COUNT(queries) AS null_queries,
    COUNT(*) FILTER (WHERE queries_imputed) AS imputed,
    SUM(queries) AS total_queries
FROM lab_dns_profile_clean;
\echo "The 8 estimated rows"
SELECT hour_start, query_status, queries
FROM lab_dns_profile_clean
WHERE queries_imputed
ORDER BY hour_start, query_status;

-- Are there any outliers now?
\echo "values more than 3 SD from their status's average"
WITH scored AS (
    SELECT hour_start, query_status, queries,
        (queries - AVG(queries) OVER by_status) / STDDEV(queries) OVER by_status AS z
    FROM lab_dns_profile_clean
    WINDOW by_status AS (PARTITION BY query_status))
SELECT hour_start, query_status, queries, ROUND(z, 1) AS z
FROM scored
WHERE ABS(z) > 3
ORDER BY query_status, hour_start;
-- OUTLIER VERDICTS (Stage H)
-- GRAVITY 3509 @ 10-15 23:00 (z 5.4): REAL. One-hour burst of ad lookups, CACHE busy too. Keep.
-- REGEX 0 x11 @ 10-20 13:00-23:00 (z -3.0): REAL. A once-a-minute device stopped;
--     other statuses normal, so the feed was fine. Keep.
-- FORWARDED 780/769, REGEX 135/120 (z 3.1-3.9): REAL. Ordinary busy hours. Keep.
-- Blocked share of all queries for the week: 33.5%


-- Is the highest result real?
SELECT hour_start, query_status, queries
FROM lab_dns_profile_clean
WHERE hour_start BETWEEN '2026-10-15 21:00' AND '2026-10-16 01:00'
    AND query_status IN ('GRAVITY', 'CACHE', 'FORWARDED')
ORDER BY query_status, hour_start;
