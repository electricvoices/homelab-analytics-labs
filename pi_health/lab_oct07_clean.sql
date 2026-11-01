-- lab_oct07_clean.sql
-- Builds lab_oct07_clean from lab_oct07_raw. Safe to rerun: starts from scratch every time.

BEGIN;

DROP TABLE IF EXISTS lab_oct07_clean;

-- Stage B: copy + deduplicate
-- Rule 2: when an hour was loaded more than once, keep the latest loaded_at.
-- ROW_NUMBER (not RANK) so exact copies with tied loaded_at also collapse to one row.
-- Removes 5 rows: 2 exact copies + 3 superseded loads

CREATE TABLE lab_oct07_clean AS
SELECT recorded_at, loaded_at, cpu_pct, mem_pct, mem_used_mb, temp_c, disk_pct
FROM (SELECT *,
        ROW_NUMBER() OVER (PARTITION BY recorded_at ORDER BY loaded_at DESC) AS row_num
    FROM lab_oct07_raw) ranked
    WHERE row_num = 1;

-- Stage C: bad values -> NULL (they are unknowns, not measurements)
UPDATE lab_oct07_clean SET cpu_pct = NULL WHERE cpu_pct NOT BETWEEN 0 AND 100; -- no 250
UPDATE lab_oct07_clean SET mem_pct = NULL WHERE mem_pct NOT BETWEEN 0 AND 100; -- no -1's
UPDATE lab_oct07_clean SET temp_c = NULL WHERE temp_c <= 0; -- 0.0 is no reading

-- Stage D (part 1): flag every gap BEFORE filling it
ALTER TABLE lab_oct07_clean
    ADD COLUMN cpu_imputed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN mem_imputed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN temp_imputed BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN disk_imputed BOOLEAN NOT NULL DEFAULT false;

UPDATE lab_oct07_clean SET cpu_imputed = true WHERE cpu_pct IS NULL;
UPDATE lab_oct07_clean SET mem_imputed = true WHERE mem_pct IS NULL;
UPDATE lab_oct07_clean SET temp_imputed = true WHERE temp_c IS NULL;
UPDATE lab_oct07_clean SET disk_imputed = true WHERE disk_pct IS NULL;

-- Stage D (part 2): fill every gap
-- Rule 4: single missing hour -> average of its neighbors;
--          consecutive missing hours -> same-hour-of-day average
-- COALESCE tries them in order; keep the real value, else the neighbor avg,
-- else the same-hour average. (A neighbor average is NULL when a neighbor is)
-- also missing, which is exactly when the gap is part of a block.)
WITH estimates AS (
    SELECT recorded_at,
        ROUND((LAG(cpu_pct) OVER by_time + LEAD(cpu_pct) OVER by_time) / 2, 1) AS cpu_n,
        ROUND((LAG(mem_pct) OVER by_time + LEAD(mem_pct) OVER by_time) / 2, 1) AS mem_n,
        ROUND((LAG(temp_c) OVER by_time + LEAD(temp_c) OVER by_time) / 2, 1) AS temp_n,
        ROUND((LAG(disk_pct) OVER by_time + LEAD(disk_pct) OVER by_time) / 2, 1) AS disk_n,
        ROUND(AVG(cpu_pct) OVER by_hour, 1) AS cpu_h,
        ROUND(AVG(mem_pct) OVER by_hour, 1) AS mem_h,
        ROUND(AVG(temp_c) OVER by_hour, 1) AS temp_h,
        ROUND(AVG(disk_pct) OVER by_hour, 1) AS disk_h
    FROM lab_oct07_clean
    WINDOW by_time AS (ORDER BY recorded_at),
        by_hour AS (PARTITION BY EXTRACT(HOUR FROM recorded_at)))
UPDATE lab_oct07_clean c
SET cpu_pct = COALESCE(c.cpu_pct, e.cpu_n, e.cpu_h),
    mem_pct = COALESCE(c.mem_pct, e.mem_n, e.mem_h),
    temp_c = COALESCE(c.temp_c, e.temp_n, e.temp_h),
    disk_pct = COALESCE(c.disk_pct, e.disk_n, e.disk_h)
FROM estimates e
WHERE c.recorded_at = e.recorded_at
    AND (c.cpu_imputed OR c.mem_imputed OR c.temp_imputed OR c.disk_imputed);

-- Stage E: remove redundancy + lock it down
-- mem_used_mb = ROUND(mem_pct * 8062 / 100) on every row (0 mismatches) -> redundant
ALTER TABLE lab_oct07_clean DROP COLUMN mem_used_mb;

-- One row per hour, and no metric may be missing or break its business rule
ALTER TABLE lab_oct07_clean
    ADD CONSTRAINT lab_oct07_clean_hour_unique UNIQUE (recorded_at),
    ALTER COLUMN recorded_at SET NOT NULL,
    ALTER COLUMN cpu_pct SET NOT NULL,
    ALTER COLUMN mem_pct SET NOT NULL,
    ALTER COLUMN temp_c SET NOT NULL,
    ALTER COLUMN disk_pct SET NOT NULL,
    ADD CONSTRAINT cpu_pct_range CHECK (cpu_pct BETWEEN 0 AND 100),
    ADD CONSTRAINT mem_pct_range CHECK (mem_pct BETWEEN 0 AND 100),
    ADD CONSTRAINT disk_pct_range CHECK (disk_pct BETWEEN 0 AND 100),
    ADD CONSTRAINT temp_c_reading CHECK (temp_c > 0);

COMMIT;

-- ====================================================================================
-- VERIFY
-- ====================================================================================
\echo '== B: one row per hour (expect 144 / 144) =='
SELECT COUNT(*) AS rows, COUNT(DISTINCT recorded_at) AS distinct_hours
FROM lab_oct07_clean;

\echo '== B: the 3 conflicting hours kept their LATEST load =='
SELECT recorded_at, loaded_at, cpu_pct, mem_pct
FROM lab_oct07_clean
WHERE recorded_at IN ('2026-10-07 21:00', '2026-10-10 17:00', '2026-10-12 19:00')
ORDER BY recorded_at;

\echo '== C/D: gaps to fill, and their flags (expect 1 / 3 / 4 / 2) =='
SELECT COUNT(*) - COUNT(cpu_pct)  AS cpu_gaps,  COUNT(*) FILTER (WHERE cpu_imputed)  AS cpu_flags,
    COUNT(*) - COUNT(mem_pct)  AS mem_gaps,  COUNT(*) FILTER (WHERE mem_imputed)  AS mem_flags,
    COUNT(*) - COUNT(temp_c)   AS temp_gaps, COUNT(*) FILTER (WHERE temp_imputed) AS temp_flags,
    COUNT(*) - COUNT(disk_pct) AS disk_gaps, COUNT(*) FILTER (WHERE disk_imputed) AS disk_flags
FROM lab_oct07_clean;

\echo '== D: no gaps left (expect 0 0 0 0) =='
SELECT COUNT(*) - COUNT(cpu_pct) AS cpu_gaps,
    COUNT(*) - COUNT(mem_pct) AS mem_gaps,
    COUNT(*) - COUNT(temp_c) AS temp_gaps,
    COUNT(*) - COUNT(disk_pct) AS disk_gaps
FROM lab_oct07_clean;

\echo '== F: final targets =='
SELECT COUNT(*) AS rows,
    COUNT(DISTINCT recorded_at) AS hours,
    COUNT(*) FILTER (WHERE cpu_imputed OR mem_imputed OR temp_imputed OR disk_imputed)
        AS rows_with_estimates,
    ROUND(AVG(cpu_pct), 1) AS avg_cpu, MAX(cpu_pct) AS max_cpu,
    ROUND(AVG(mem_pct), 1) AS avg_mem, MIN(mem_pct) AS min_mem, MAX(mem_pct) AS max_mem,
    ROUND(AVG(temp_c), 1) AS avg_temp, MIN(temp_c) AS min_temp, MAX(temp_c) AS max_temp,
    ROUND(AVG(disk_pct), 1) AS avg_disk
FROM lab_oct07_clean;
