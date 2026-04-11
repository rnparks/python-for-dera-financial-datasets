-- peer_zscore_by_sub_industry — cross-sectional z-scores by GICS peer group.
--
-- Pre-computed so quant screens get instant "rank vs. peers" without
-- re-running window functions over num_silver on every query. One row
-- per (ticker, concept, fiscal_year). Z-score is computed within
-- (concept, fiscal_year, sub_industry):
--
--     zscore = (value - peer_mean) / NULLIF(peer_stddev, 0)
--
-- Fiscal year is bucketed by EXTRACT(YEAR FROM value_date), so NVDA's
-- Jan 2025 fiscal year-end rolls into fiscal_year = 2025 alongside
-- Apple's Sep 2025 and MSFT's June 2025. Peers are grouped by
-- gics_sub_industry from universe_sp1500. Only groups with ≥5
-- reporting companies are kept — smaller groups produce meaningless
-- z-scores.
--
-- Implementation notes:
--   - Sources from sec_gold.tradable_financials (11.2M pre-filtered
--     rows) instead of sec_silver.num_silver (177M) — the matview is
--     already S&P 1500, rank_latest=1, and segments/coreg filtered,
--     which is exactly the population we want. Dropping the source
--     from 177M → 11.2M cuts build time by roughly an order of
--     magnitude.
--   - DISTINCT ON (ticker, concept, fiscal_year) with the ORDER BY
--     `m.priority, value_date DESC` picks the best-priority tag
--     match per company-year in a single pass.
--   - Matches only sic_prefix = '' rows in concept_tag_map. The
--     bank-specific rows (sic_prefix = '60') are redundant here
--     because banks also match the generic priority-2 'Revenues' row,
--     and other non-bank companies use RFCWEAT at priority 1.
--   - SET LOCAL work_mem = '1GB' so the hash aggregate stays in
--     memory (default 4MB spills heavily).

SET LOCAL work_mem             = '1GB';
SET LOCAL maintenance_work_mem = '1GB';

DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_zscore_by_sub_industry CASCADE;

CREATE MATERIALIZED VIEW sec_gold.peer_zscore_by_sub_industry AS
WITH resolved AS (
    SELECT DISTINCT ON (tf.ticker, m.concept, EXTRACT(YEAR FROM tf.value_date))
        tf.ticker,
        u.gics_sector,
        u.gics_sub_industry,
        m.concept,
        c.fact_type,
        EXTRACT(YEAR FROM tf.value_date)::INT AS fiscal_year,
        tf.value_date,
        tf.value * m.sign_multiplier AS value
    FROM sec_gold.tradable_financials  tf
    JOIN sec_gold.concept_tag_map      m ON m.tag = tf.tag
    JOIN sec_gold.canonical_concepts   c ON c.concept = m.concept
    JOIN sec_silver.universe_sp1500    u ON u.ticker = tf.ticker
    WHERE tf.qtrs = CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
      AND c.fact_type <> 'derived'
      AND m.sic_prefix = ''
      AND u.gics_sub_industry IS NOT NULL
    ORDER BY
        tf.ticker, m.concept, EXTRACT(YEAR FROM tf.value_date),
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
    r.value,
    p.peer_count,
    p.peer_mean,
    p.peer_stddev,
    p.peer_min,
    p.peer_max,
    CASE
        WHEN p.peer_stddev IS NULL OR p.peer_stddev = 0 THEN NULL
        ELSE ((r.value - p.peer_mean) / p.peer_stddev)::NUMERIC(12,4)
    END AS zscore
FROM resolved   r
JOIN peer_stats p USING (concept, fiscal_year, gics_sub_industry);

CREATE INDEX idx_zscore_ticker  ON sec_gold.peer_zscore_by_sub_industry (ticker);
CREATE INDEX idx_zscore_concept ON sec_gold.peer_zscore_by_sub_industry (concept, fiscal_year);
CREATE INDEX idx_zscore_sub_ind ON sec_gold.peer_zscore_by_sub_industry (gics_sub_industry, fiscal_year, concept);
