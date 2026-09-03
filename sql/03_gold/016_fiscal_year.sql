-- Fiscal-year alignment for cross-sectional comparison.
--
-- The problem: comparing companies by `EXTRACT(YEAR FROM value_date)`
-- misaligns anyone whose fiscal year does not end in December. NVIDIA
-- and Walmart both close at the end of January, so their year ending
-- 2025-01-31 covers February 2024 through January 2025 -- economically
-- almost entirely calendar 2024. Bucketing it as 2025 compares eleven
-- months of their operations against a full, later year of a
-- December filer's.
--
-- The rule below assigns a period to the calendar year in which most of
-- it elapsed: a period ending January through May belongs to the prior
-- year, June through December to its own.
--
-- Note this deliberately differs from the company's own label. NVIDIA
-- calls the year ending January 2025 "fiscal 2025". For peer
-- comparison what matters is aligning economic periods, so that year
-- sits alongside a December filer's 2024. This function returns a
-- comparison key, not a name to print.
--
-- SEC's own `fy` field was considered and rejected: it is internally
-- inconsistent in this dataset, reporting fy=2026 for a period ending
-- 2026-01-31 and fy=2024 for one ending 2025-01-31 at the same filer.
-- A deterministic rule beats an unreliable input.

CREATE OR REPLACE FUNCTION sec_gold.fiscal_year_of(p_period_end DATE)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT CASE
        WHEN p_period_end IS NULL THEN NULL
        WHEN EXTRACT(MONTH FROM p_period_end) <= 5
            THEN EXTRACT(YEAR FROM p_period_end)::INT - 1
        ELSE EXTRACT(YEAR FROM p_period_end)::INT
    END;
$$;

COMMENT ON FUNCTION sec_gold.fiscal_year_of(DATE) IS
    'Calendar year in which most of a fiscal period elapsed. Use as a '
    'peer-comparison key so non-December filers align with December '
    'ones. Not the company''s own fiscal-year label.';
