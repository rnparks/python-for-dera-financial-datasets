-- peer_zscore_by_sub_industry — cross-sectional scores by GICS peer group.
--
-- SCOPE WARNING: this is a dashboard and screening artifact, NOT a
-- backtest input. It is built from `tradable_financials`, which holds
-- restated values, and the peer statistics are computed over the
-- finished panel, so both the inputs and the moments know the future.
-- Making it availability-correct means recomputing per knowledge date,
-- which is a different object entirely. Anything backtested should read
-- sec_gold.fact_asof and compute its own cross-section.
--
-- One row per (ticker, concept, fiscal_year).
--
-- Three defects fixed here:
--
-- 1. Fiscal-year bucketing. The old `EXTRACT(YEAR FROM value_date)`
--    put NVIDIA's and Walmart's fiscal years, which end in January,
--    into the following calendar year, comparing eleven months of one
--    company's operations against a full year of its peers'. SEC's own
--    `fy` field is not a safe substitute: it is internally inconsistent
--    in this dataset, reporting fy=2026 for a period ending 2026-01-31
--    and fy=2024 for one ending 2025-01-31 at the same filer. A
--    deterministic month rule is used instead: a period ending in
--    January through May belongs to the prior fiscal year.
--
-- 2. Unbounded value_date. DERA publishes filer typos as-is, spanning
--    1980 to 2031. Left unbounded they poison the peer moments.
--
-- 3. Bank exclusion. Forcing `sic_prefix = ''` discarded the
--    industry-specific tag rows, so banks fell through to generic tags
--    or resolved to nothing. Industry-specific entries are now allowed
--    and preferred when the company's SIC matches.
--
-- Raw-dollar z-scores remain the headline number and remain a measure
-- of scale as much as performance: within a sub-industry, company size
-- spans orders of magnitude, so a z of +4 on revenue mostly means
-- "much bigger than peers". A rank-based percentile is published
-- alongside it, which is robust to that skew and usually the more
-- honest cross-sectional signal.

SET LOCAL work_mem             = '1GB';
SET LOCAL maintenance_work_mem = '1GB';

DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_zscore_by_sub_industry CASCADE;

CREATE MATERIALIZED VIEW sec_gold.peer_zscore_by_sub_industry AS
WITH resolved AS (
    SELECT DISTINCT ON (tf.ticker, m.concept, sec_gold.fiscal_year_of(tf.value_date))
        tf.ticker,
        u.gics_sector,
        u.gics_sub_industry,
        m.concept,
        c.fact_type,
        sec_gold.fiscal_year_of(tf.value_date) AS fiscal_year,
        tf.value_date,
        tf.tradable_from,
        tf.value * m.sign_multiplier AS value
    FROM sec_gold.tradable_financials  tf
    JOIN sec_gold.concept_tag_map      m ON m.tag = tf.tag
    JOIN sec_gold.canonical_concepts   c ON c.concept = m.concept
    JOIN sec_silver.universe_sp1500    u ON u.ticker = tf.ticker
    LEFT JOIN sec_reference.company    co ON co.cik = tf.cik
    WHERE tf.qtrs = CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
      AND c.fact_type <> 'derived'
      AND tf.value IS NOT NULL
      AND u.gics_sub_industry IS NOT NULL
      -- Industry-specific tags are now eligible, not excluded.
      AND (m.sic_prefix = '' OR co.sic_latest::TEXT LIKE m.sic_prefix || '%')
      AND tf.value_date >= DATE '2008-01-01'
      AND tf.value_date <= CURRENT_DATE + INTERVAL '1 year'
    ORDER BY
        tf.ticker, m.concept, sec_gold.fiscal_year_of(tf.value_date),
        -- industry-specific beats generic, then declared priority
        m.sic_prefix <> '' DESC,
        m.priority ASC,
        tf.value_date DESC
),
peer_stats AS (
    SELECT
        concept, fiscal_year, gics_sub_industry,
        COUNT(*)                     AS peer_count,
        AVG(value)::NUMERIC          AS peer_mean,
        STDDEV_SAMP(value)::NUMERIC  AS peer_stddev,
        MIN(value)::NUMERIC          AS peer_min,
        MAX(value)::NUMERIC          AS peer_max
    FROM resolved
    GROUP BY concept, fiscal_year, gics_sub_industry
    HAVING COUNT(*) >= 5
)
SELECT
    r.ticker,
    r.gics_sector,
    r.gics_sub_industry,
    r.concept,
    r.fact_type,
    r.fiscal_year,
    r.value_date,
    r.tradable_from,
    r.value,
    p.peer_count,
    p.peer_mean,
    p.peer_stddev,
    p.peer_min,
    p.peer_max,
    CASE
        WHEN p.peer_stddev IS NULL OR p.peer_stddev = 0 THEN NULL
        ELSE ((r.value - p.peer_mean) / p.peer_stddev)::NUMERIC(12,4)
    END AS zscore,
    -- Rank-based, so a single mega-cap cannot compress the rest of the
    -- group into a narrow negative band the way the z-score does.
    ROUND(
        PERCENT_RANK() OVER (
            PARTITION BY r.concept, r.fiscal_year, r.gics_sub_industry
            ORDER BY r.value
        )::NUMERIC, 4
    ) AS peer_percentile
FROM resolved   r
JOIN peer_stats p USING (concept, fiscal_year, gics_sub_industry);

CREATE INDEX idx_zscore_ticker  ON sec_gold.peer_zscore_by_sub_industry (ticker);
CREATE INDEX idx_zscore_concept ON sec_gold.peer_zscore_by_sub_industry (concept, fiscal_year);
CREATE INDEX idx_zscore_sub_ind ON sec_gold.peer_zscore_by_sub_industry (gics_sub_industry, fiscal_year, concept);

COMMENT ON MATERIALIZED VIEW sec_gold.peer_zscore_by_sub_industry IS
    'Dashboard/screening only. Built from restated values with peer '
    'moments computed over the finished panel, so it is NOT '
    'availability-correct. Backtests should read fact_asof.';
COMMENT ON COLUMN sec_gold.peer_zscore_by_sub_industry.zscore IS
    'Raw-value z-score: measures scale as much as performance. Prefer '
    'peer_percentile for size-skewed concepts.';
