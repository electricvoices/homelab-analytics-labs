-- lab_oct07_profile.sql
-- Stage A: profiling lab_oct07_raw (Pi health export, Oct 7 00:00 - Oct 12 23:00).
-- Read-only: SELECT statements only. Safe to rerun at any time.

-- ============================================================
-- TABLE LEVEL
-- ============================================================

\echo '== A1/A2: grain (one row per hour) + row count (expect 144) =='
-- RESULT: BROKEN - 149 rows but only 144 distinct hours -> 5 extra rows
SELECT COUNT(*) AS total_rows,
    COUNT(DISTINCT recorded_at) AS distinct_hours
FROM lab_oct07_raw;

\echo '== A3: every hour inside Oct 7 00:00 - Oct 12 23:00 =='
-- RESULT: HOLDS
SELECT MIN(recorded_at) AS first_hour,
    MAX(recorded_at) AS last_hour
FROM lab_oct07_raw;

\echo '== A4: loaded_at never earlier than recorded_at =='
-- RESULT: HOLDS - 0 rows break it
SELECT COUNT(*) FILTER (WHERE loaded_at < recorded_at) AS loaded_before_recorded
FROM lab_oct07_raw;

-- ============================================================
-- DUPLICATES
-- ============================================================

\echo '== A5: repeated hours - exact copies or conflicting? =='
-- RESULT: BROKEN - versions = 1: exact copies (10-08 07:00, 10-11 22:00)
--                  versions = 2: conflicting reloads (10-07 21:00, 10-10 17:00, 10-12 19:00)
--         Rule 2: keep the copy with the latest loaded_at
SELECT recorded_at,
    COUNT(*) AS copies,
    COUNT(DISTINCT (cpu_pct, mem_pct, mem_used_mb, temp_c, disk_pct)) AS versions
FROM lab_oct07_raw
GROUP BY recorded_at
HAVING COUNT(*) > 1
ORDER BY recorded_at;

\echo '== A5 detail: the repeated rows side by side =='
SELECT *
FROM lab_oct07_raw
WHERE recorded_at IN (
    SELECT recorded_at
    FROM lab_oct07_raw
    GROUP BY recorded_at
    HAVING COUNT(*) > 1)
ORDER BY recorded_at, loaded_at;

-- ============================================================
-- VALIDITY / COMPLETENESS (one profile per column)
-- ============================================================

\echo '== A6/A9: cpu_pct profile (rule: 0-100) =='
-- RESULT: BROKEN - max 250.0, 1 out of range
SELECT COUNT(*) - COUNT(cpu_pct) AS nulls,
    MIN(cpu_pct) AS min, MAX(cpu_pct) AS max,
    COUNT(*) FILTER (WHERE cpu_pct NOT BETWEEN 0 AND 100) AS out_of_range
FROM lab_oct07_raw;

\echo '== A6/A8/A9: mem_pct profile (rule: 0-100) =='
-- RESULT: BROKEN - min -1 (placeholder), 3 out of range
SELECT COUNT(*) - COUNT(mem_pct) AS nulls,
    MIN(mem_pct) AS min, MAX(mem_pct) AS max,
    COUNT(*) FILTER (WHERE mem_pct NOT BETWEEN 0 AND 100) AS out_of_range
FROM lab_oct07_raw;

\echo '== A7/A8/A9: temp_c profile (rule: never 0 or below) =='
-- RESULT: BROKEN - min 0.0 (placeholder), 4 rule-breakers
SELECT COUNT(*) - COUNT(temp_c) AS nulls,
    MIN(temp_c) AS min, MAX(temp_c) AS max,
    COUNT(*) FILTER (WHERE temp_c <= 0) AS rule_breakers
FROM lab_oct07_raw;

\echo '== A6/A9: disk_pct profile (rule: 0-100) =='
-- RESULT: BROKEN - 2 NULLs
SELECT COUNT(*) - COUNT(disk_pct) AS nulls,
    MIN(disk_pct) AS min, MAX(disk_pct) AS max,
    COUNT(*) FILTER (WHERE disk_pct NOT BETWEEN 0 AND 100) AS out_of_range
FROM lab_oct07_raw;

\echo '== A6-A9: every row that breaks a rule =='
-- RESULT: 10 problem values
--   mem -1 (placeholder)  x3, single hours:  10-07 15:00, 10-09 20:00, 10-11 06:00
--   temp 0.0 (no reading) x4, one block:     10-10 09:00 - 12:00
--   cpu 250.0 (impossible) x1, single hour:  10-09 04:00
--   disk NULL              x2, single hours: 10-08 13:00, 10-12 02:00
SELECT recorded_at, cpu_pct, mem_pct, temp_c, disk_pct
FROM lab_oct07_raw
WHERE cpu_pct NOT BETWEEN 0 AND 100
    OR mem_pct NOT BETWEEN 0 AND 100
    OR temp_c <= 0
    OR disk_pct IS NULL
ORDER BY recorded_at;

-- ============================================================
-- CONSISTENCY (redundancy)
-- ============================================================

\echo '== A10: is mem_used_mb just mem_pct in other units? (8062 MB total) =='
-- RESULT: BROKEN - ratio 80.60-80.64 (rounding), 0 mismatches -> redundant, drop it
SELECT ROUND(MIN(mem_used_mb / mem_pct), 2) AS lowest_ratio,
    ROUND(MAX(mem_used_mb / mem_pct), 2) AS highest_ratio
FROM lab_oct07_raw
WHERE mem_pct > 0;

SELECT COUNT(*) AS rows_checked,
    COUNT(*) FILTER (WHERE mem_used_mb <> ROUND(mem_pct * 8062 / 100)) AS mismatches
FROM lab_oct07_raw;

-- ============================================================
-- ACCURACY (outliers) - known errors excluded first
-- ============================================================

\echo '== A11: mem_pct values with |z| > 3 =='
-- RESULT: 10-11 17:00 (68.9, z 9.6) and 18:00 (46.2, z 3.6) -> REAL, keep
--         (builds up and down, CPU and disk peak at the same time)
WITH scored AS (
    SELECT recorded_at, mem_pct,
        ROUND((mem_pct - AVG(mem_pct) OVER ()) / STDDEV(mem_pct) OVER (), 1) AS z
    FROM lab_oct07_raw
    WHERE mem_pct BETWEEN 0 AND 100)
SELECT recorded_at, mem_pct, z
FROM scored
WHERE ABS(z) > 3
ORDER BY recorded_at;

\echo '== A11: biggest |z| in cpu_pct / temp_c / disk_pct =='
-- RESULT: cpu 1.4, temp 1.6 -> no outliers
--         disk 4.7 (34.6 at 10-11 16-17:00) -> real but trivial (sd only 0.10), keep
WITH scored AS (
    SELECT ROUND((cpu_pct - AVG(cpu_pct) OVER ()) / STDDEV(cpu_pct) OVER (), 1) AS z
    FROM lab_oct07_raw
    WHERE cpu_pct BETWEEN 0 AND 100)
SELECT 'cpu_pct' AS col, MAX(ABS(z)) AS biggest_z FROM scored;

WITH scored AS (
    SELECT ROUND((temp_c - AVG(temp_c) OVER ()) / STDDEV(temp_c) OVER (), 1) AS z
    FROM lab_oct07_raw
    WHERE temp_c > 0)
SELECT 'temp_c' AS col, MAX(ABS(z)) AS biggest_z FROM scored;

WITH scored AS (
    SELECT ROUND((disk_pct - AVG(disk_pct) OVER ()) / STDDEV(disk_pct) OVER (), 1) AS z
    FROM lab_oct07_raw
    WHERE disk_pct IS NOT NULL)
SELECT 'disk_pct' AS col, MAX(ABS(z)) AS biggest_z FROM scored;

\echo '== A11 context: all metrics around the Oct 11 spike =='
SELECT recorded_at, cpu_pct, mem_pct, disk_pct
FROM lab_oct07_raw
WHERE recorded_at BETWEEN '2026-10-11 15:00' AND '2026-10-11 19:00'
ORDER BY recorded_at;
