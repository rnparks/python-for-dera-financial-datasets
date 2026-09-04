-- peer_stats — cross-sectional scores at two GICS levels at once.
--
-- SCOPE WARNING: this is a dashboard and screening artifact, NOT a
-- backtest input. It is built from `tradable_financials`, which holds
-- restated values, and the peer moments are computed over the finished
-- panel, so both the inputs and the statistics know the future. Making
-- it availability-correct means recomputing per knowledge date, which
-- is a different object. Anything backtested should read
-- sec_gold.fact_asof and build its own cross-section.
--
-- WHY TWO LEVELS. Sub-industry alone was too granular to be useful.
-- On the live data only 101 of 155 groups cleared the five-member
-- threshold, and just 1,358 companies got scored. The threshold does
-- not degrade a thin group, it deletes it, so 147 companies vanished
-- from peer scoring with nothing in the output to say so. At sector
-- level all 1,505 are scored across 11 groups and nobody is dropped.
--
-- Rather than choose once and bake it in, both levels are computed and
-- tagged with `peer_level`. Roughly doubling a 110K-row table costs
-- nothing, and it turns an irreversible modelling decision into a
-- query-time filter:
--
--   WHERE peer_level = 'sector'        -- 11 groups, stable moments
--   WHERE peer_level = 'sub_industry'  -- finer, but thin and lossy
--
-- Statistically sector is the sounder default. The standard error of an
-- estimated standard deviation is about sigma/sqrt(2(n-1)), so at the
-- sub-industry median of seven companies the z-score denominator is
-- itself uncertain by nearly 30%. At sector the smallest group is
-- Communication Services at 50, which lands near 10%.
--
-- Raw-dollar z-scores remain a measure of scale as much as performance:
-- within any group company size spans orders of magnitude, so a z of +4
-- on revenue mostly means "much bigger than peers". peer_percentile is
-- published alongside and is robust to that skew. Note the percentile
-- degrades in thin groups too: PERCENT_RANK on five companies can only
-- return 0, 0.25, 0.5, 0.75 or 1.
--
-- Replaces peer_zscore_by_sub_industry, which became a misleading name
-- once the table held more than one level.

SET LOCAL work_mem             = '1GB';
SET LOCAL maintenance_work_mem = '1GB';

DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_zscore_by_sub_industry CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_stats                  CASCADE;

-- MEMBERSHIP IS AS OF THE FISCAL PERIOD END. A company enters a fiscal
-- year's cross-section only if it was an index constituent on that
-- period's end date, resolved directly against index_membership here
-- rather than through tradable_financials.index_is_asof: that flag is
-- evaluated at the availability of the LATEST vintage, and for an
-- annual fact the latest vintage is usually the comparative reprinted
-- in a 10-K one or two years on -- Tesla's FY2018 revenue survives as
-- the row from its FY2020 10-K, filed after it joined the index. The
-- period end is vintage-independent and is what "in the index that
-- year" means. For the S&P 500 that is the replayed history, so a FY2012
-- cross-section scores 2012's members -- SVB, Sears and the rest -- not
-- today's; for the S&P 400 and 600 it is today's list at every date
-- until their history is replayed, labelled as such in
-- index_membership.source. Before this the panel was today's S&P 1500 at
-- every fiscal year, survivorship bias by construction.

CREATE MATERIALIZED VIEW sec_gold.peer_stats AS
WITH direct AS (
    -- One value per (company, concept, fiscal year), picking the
    -- best-priority tag. Industry-specific tag rows are eligible and
    -- preferred where the company's SIC matches; excluding them used to
    -- leave banks resolving to generic tags or to nothing at all.
    SELECT DISTINCT ON (tf.cik, m.concept, sec_gold.fiscal_year_of(tf.value_date))
        tf.cik,
        tf.ticker,
        mem.index_name,
        mem.gics_sector,
        mem.gics_sub_industry,
        m.concept,
        c.fact_type,
        sec_gold.fiscal_year_of(tf.value_date) AS fiscal_year,
        tf.value_date,
        tf.tradable_from,
        tf.value * m.sign_multiplier AS value
    FROM sec_gold.tradable_financials  tf
    JOIN sec_gold.concept_tag_map      m ON m.tag = tf.tag
    JOIN sec_gold.canonical_concepts   c ON c.concept = m.concept
    LEFT JOIN sec_reference.company    co ON co.cik = tf.cik
    -- Membership and classification on the period end date.
    JOIN LATERAL (
        SELECT im.index_name, im.gics_sector, im.gics_sub_industry
        FROM sec_reference.index_membership im
        WHERE im.cik = tf.cik
          AND im.valid_from <= tf.value_date
          AND (im.valid_to IS NULL OR im.valid_to > tf.value_date)
        ORDER BY (im.source = 'wikipedia_history') DESC, im.valid_from DESC
        LIMIT 1
    ) mem ON TRUE
    WHERE tf.qtrs = CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
      AND tf.value IS NOT NULL
      AND (m.sic_prefix = '' OR co.sic_latest::TEXT LIKE m.sic_prefix || '%')
      -- DERA publishes filer typos as-is, spanning 1980 to 2031. Left
      -- unbounded they poison the peer moments.
      AND tf.value_date >= DATE '2008-01-01'
      AND tf.value_date <= CURRENT_DATE + INTERVAL '1 year'
    ORDER BY
        tf.cik, m.concept, sec_gold.fiscal_year_of(tf.value_date),
        m.sic_prefix <> '' DESC,
        m.priority ASC,
        tf.value_date DESC
),
-- Derived concepts, assembled from what the tag walk just resolved.
--
-- peer_stats is tag-driven, so a concept with no tags could never appear
-- here no matter what the resolver did. That is why free_cash_flow has
-- been invisible in every screen since it was declared. Computing the
-- formulas against `direct` fixes that, and it also picks up the debt
-- and gross-profit recoveries, since both fall back to a formula.
--
-- Only fires where the direct walk produced nothing for that
-- company-year: an issuer filing GrossProfit outright keeps its filed
-- figure rather than a reconstruction.
derived AS (
    SELECT
        d.cik,
        max(d.ticker)            AS ticker,
        max(d.index_name)        AS index_name,
        max(d.gics_sector)       AS gics_sector,
        max(d.gics_sub_industry) AS gics_sub_industry,
        f.concept,
        max(c.fact_type)         AS fact_type,
        d.fiscal_year,
        max(d.value_date)        AS value_date,
        max(d.tradable_from)     AS tradable_from,
        sum(f.coefficient * d.value) AS value
    FROM sec_gold.concept_formula   f
    JOIN direct                     d ON d.concept = f.operand
    JOIN sec_gold.canonical_concepts c ON c.concept = f.concept
    WHERE NOT EXISTS (
        SELECT 1 FROM direct d2
        WHERE d2.cik = d.cik AND d2.concept = f.concept
          AND d2.fiscal_year = d.fiscal_year
    )
    GROUP BY d.cik, f.concept, d.fiscal_year
    HAVING count(*) FILTER (WHERE f.required)
         = (SELECT count(*) FROM sec_gold.concept_formula f2
             WHERE f2.concept = f.concept AND f2.required)
),
resolved AS (
    SELECT * FROM direct
    UNION ALL
    SELECT * FROM derived
),
-- Fan the same resolved population out across both grouping levels.
-- `peer_group` carries whichever label applies, so every downstream
-- calculation is written once rather than duplicated per level.
levelled AS (
    SELECT r.*, 'sector'::TEXT AS peer_level, r.gics_sector AS peer_group
    FROM resolved r WHERE r.gics_sector IS NOT NULL
    UNION ALL
    SELECT r.*, 'sub_industry'::TEXT, r.gics_sub_industry
    FROM resolved r WHERE r.gics_sub_industry IS NOT NULL
),
moments AS (
    SELECT
        concept, fiscal_year, peer_level, peer_group,
        COUNT(*)                     AS peer_count,
        AVG(value)::NUMERIC          AS peer_mean,
        STDDEV_SAMP(value)::NUMERIC  AS peer_stddev,
        MIN(value)::NUMERIC          AS peer_min,
        MAX(value)::NUMERIC          AS peer_max
    FROM levelled
    GROUP BY concept, fiscal_year, peer_level, peer_group
    HAVING COUNT(*) >= 5
)
SELECT
    l.cik,
    l.ticker,
    l.index_name,
    l.gics_sector,
    l.gics_sub_industry,
    l.concept,
    l.fact_type,
    l.fiscal_year,
    l.peer_level,
    l.peer_group,
    l.value_date,
    l.tradable_from,
    l.value,
    p.peer_count,
    p.peer_mean,
    p.peer_stddev,
    p.peer_min,
    p.peer_max,
    CASE
        WHEN p.peer_stddev IS NULL OR p.peer_stddev = 0 THEN NULL
        ELSE ((l.value - p.peer_mean) / p.peer_stddev)::NUMERIC(12,4)
    END AS zscore,
    ROUND(
        PERCENT_RANK() OVER (
            PARTITION BY l.concept, l.fiscal_year, l.peer_level, l.peer_group
            ORDER BY l.value
        )::NUMERIC, 4
    ) AS peer_percentile
FROM levelled l
JOIN moments  p USING (concept, fiscal_year, peer_level, peer_group);

CREATE INDEX idx_peerstats_ticker  ON sec_gold.peer_stats (ticker);
CREATE INDEX idx_peerstats_cik     ON sec_gold.peer_stats (cik);
CREATE INDEX idx_peerstats_index   ON sec_gold.peer_stats (index_name, fiscal_year);
CREATE INDEX idx_peerstats_lookup  ON sec_gold.peer_stats (peer_level, concept, fiscal_year);
CREATE INDEX idx_peerstats_group   ON sec_gold.peer_stats (peer_level, peer_group, fiscal_year, concept);

COMMENT ON MATERIALIZED VIEW sec_gold.peer_stats IS
    'Cross-sectional peer scores at two GICS levels. Filter on '
    'peer_level (''sector'' or ''sub_industry''). Dashboard and '
    'screening only: built from restated values with moments over the '
    'finished panel, so it is NOT availability-correct. Backtests '
    'should read fact_asof.';
COMMENT ON COLUMN sec_gold.peer_stats.index_name IS
    'Index the company belonged to on the fiscal period end date. SP500 '
    'from replayed history; SP400/SP600 from today''s snapshot until '
    'their history is replayed.';
COMMENT ON COLUMN sec_gold.peer_stats.peer_level IS
    'Which GICS level this row was scored against. Sector is the '
    'sounder default; sub_industry is finer but thin, and groups below '
    'five members are dropped entirely rather than degraded.';
COMMENT ON COLUMN sec_gold.peer_stats.zscore IS
    'Raw-value z-score: measures scale as much as performance. Prefer '
    'peer_percentile for size-skewed concepts, and treat both with '
    'suspicion when peer_count is small.';
