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
-- PLAN SHAPE, PINNED. Joining tradable_financials to concept_tag_map on
-- tag is a 62-row outer against a 12.4M-row inner, and the planner's
-- estimate for "rows per tag" is the table-wide average (~3,000), so it
-- picks a nested loop of per-tag bitmap scans. The mapped tags are the
-- most common ones -- millions of rows each -- and that plan ran past
-- 37 minutes on a REFRESH; with nested loops and bitmap scans off it is
-- a parallel sequential scan and hash joins, 21 seconds. The refresh
-- path in dera_pipeline.cli sets the same two for this matview.
SET LOCAL enable_nestloop   = off;
SET LOCAL enable_bitmapscan = off;

DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_zscore_by_sub_industry CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.peer_stats                  CASCADE;

-- MEMBERSHIP IS AS OF THE FISCAL PERIOD END. A company enters a fiscal
-- year's cross-section only if it was an index constituent on that
-- period's end date, resolved directly against the membership timeline
-- here rather than through tradable_financials.index_is_asof: that flag is
-- evaluated at the availability of the LATEST vintage, and for an
-- annual fact the latest vintage is usually the comparative reprinted
-- in a 10-K one or two years on -- Tesla's FY2018 revenue survives as
-- the row from its FY2020 10-K, filed after it joined the index. The
-- period end is vintage-independent and is what "in the index that
-- year" means. For the S&P 500 that is the replayed history, so a FY2012
-- cross-section scores 2012's members -- SVB, Sears and the rest -- not
-- today's; the S&P 400 (from 2011) and 600 (from 2018) are replayed the
-- same way. Before this the panel was today's S&P 1500 at every fiscal
-- year, survivorship bias by construction.

CREATE MATERIALIZED VIEW sec_gold.peer_stats AS
WITH picked AS (
    -- One value per (company, concept, fiscal year), picking the
    -- best-priority tag. Industry-specific tag rows are eligible and
    -- preferred where the company's SIC matches; excluding them used to
    -- leave banks resolving to generic tags or to nothing at all.
    --
    -- Membership is joined AFTER this pick, on ~110K rows, not before it
    -- on ~15M. Joined before, the planner estimated the fact side at 77
    -- rows, materialised it and nested-looped the 2,931-row timeline
    -- over it -- a build that took 16 seconds ran past ten minutes,
    -- twice. Picking first makes the join's cost independent of that
    -- estimate. Since 6b put every balance on the fiscal year-end, the
    -- rows a company-year can pick from share one date, so filtering on
    -- membership after the pick decides the same population.
    SELECT DISTINCT ON (tf.cik, m.concept, sec_gold.fiscal_year_of(tf.value_date))
        tf.cik,
        tf.ticker,
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
    WHERE tf.qtrs = CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
      AND tf.value IS NOT NULL
      -- A BALANCE BELONGS TO ITS FISCAL YEAR-END. fiscal_year_of() maps a
      -- period ending January to May to the prior year (so NVIDIA's
      -- January close aligns with December filers), and a December
      -- filer's Q1 balance dated 2025-03-31 therefore sits inside
      -- "FY2024" too -- and, being the latest date in the window, won
      -- the DISTINCT ON: 86% of FY2024 balance rows (6,324 of 7,378)
      -- were Q1 10-Q balances, so a FY2024 leverage ratio divided
      -- December flows by March debt. A balance is admitted only when
      -- the company reports an annual (qtrs = 4) period ending on that
      -- same date, which is what "the fiscal year-end balance" means
      -- here without trusting SEC's inconsistent fy field.
      AND (c.fact_type <> 'balance'
           OR EXISTS (SELECT 1 FROM sec_gold.tradable_financials ae
                       WHERE ae.cik = tf.cik AND ae.value_date = tf.value_date AND ae.qtrs = 4))
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
-- Membership and classification on the period end date, from the
-- non-overlapping timeline (05_spine/020, section 3c). A company-year
-- whose period end falls outside every membership interval is not in
-- the panel: the cross-section is the index of the time.
direct AS (
    SELECT p.cik, p.ticker,
           mem.index_name, mem.gics_sector, mem.gics_sub_industry,
           p.concept, p.fact_type, p.fiscal_year, p.value_date, p.tradable_from, p.value
    FROM picked p
    JOIN sec_reference.index_membership_timeline mem
      ON mem.cik = p.cik
     AND mem.valid_from <= p.value_date
     AND (mem.valid_to IS NULL OR mem.valid_to > p.value_date)
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
-- Scale-free concepts (concept_ratio). A ratio divides two resolved
-- concepts of the same company and fiscal year -- and since a balance
-- row is the fiscal year-end balance, ROE is FY net income over FY-end
-- equity. Growth compares a concept with the company's own prior fiscal
-- year, and only when that prior period really is one year back: a
-- fiscal-year change or a gap in filings must not read as growth. A
-- denominator or base that is not positive gives no row at all rather
-- than a number nobody should rank on. These then get the same peer
-- moments and percentiles as the dollar concepts, which is the point:
-- a z-score on net margin means something a z-score on revenue does not.
--
-- Shape matters here: `resolved` is a CTE, and a self-join on a CTE
-- gets no index and a row estimate the planner cannot trust -- the first
-- version was a nested loop over 110K rows a side and ran past ten
-- minutes. Ratios therefore come from one GROUP BY per company-year
-- (the concepts folded into a jsonb map, which keeps numeric exact) and
-- growth from a window function; neither joins `resolved` to itself.
by_key AS (
    SELECT cik, fiscal_year,
           MAX(ticker) AS ticker, MAX(index_name) AS index_name,
           MAX(gics_sector) AS gics_sector, MAX(gics_sub_industry) AS gics_sub_industry,
           jsonb_object_agg(concept, value)         AS vals,
           jsonb_object_agg(concept, value_date)    AS dates,
           jsonb_object_agg(concept, tradable_from) AS avail
    FROM resolved
    GROUP BY cik, fiscal_year
),
ratios AS (
    SELECT k.cik, k.ticker, k.index_name, k.gics_sector, k.gics_sub_industry,
           r.concept, c.fact_type, k.fiscal_year,
           (k.dates ->> r.numerator)::date AS value_date,
           GREATEST((k.avail ->> r.numerator)::date, (k.avail ->> r.denominator)::date) AS tradable_from,
           (k.vals ->> r.numerator)::numeric / (k.vals ->> r.denominator)::numeric AS value
    FROM by_key k
    CROSS JOIN sec_gold.concept_ratio r
    JOIN sec_gold.canonical_concepts c ON c.concept = r.concept
    WHERE r.kind = 'ratio'
      AND (k.vals ->> r.numerator)   IS NOT NULL
      AND (k.vals ->> r.denominator) IS NOT NULL
      AND (k.vals ->> r.denominator)::numeric > 0
),
growth AS (
    SELECT g.cik, g.ticker, g.index_name, g.gics_sector, g.gics_sub_industry,
           g.concept, g.fact_type, g.fiscal_year, g.value_date, g.tradable_from,
           (g.value - g.prior_value) / g.prior_value AS value
    FROM (
        SELECT x.cik, x.ticker, x.index_name, x.gics_sector, x.gics_sub_industry,
               r.concept, c.fact_type, x.fiscal_year, x.value_date, x.tradable_from, x.value,
               LAG(x.value)       OVER w AS prior_value,
               LAG(x.fiscal_year) OVER w AS prior_fiscal_year,
               LAG(x.value_date)  OVER w AS prior_value_date
        FROM sec_gold.concept_ratio r
        JOIN sec_gold.canonical_concepts c ON c.concept = r.concept
        JOIN resolved x ON x.concept = r.numerator
        WHERE r.kind = 'growth'
        WINDOW w AS (PARTITION BY r.concept, x.cik ORDER BY x.fiscal_year)
    ) g
    WHERE g.prior_fiscal_year = g.fiscal_year - 1
      AND g.prior_value > 0
      AND g.value_date - g.prior_value_date BETWEEN 300 AND 430
),
resolved_all AS (
    SELECT * FROM resolved
    UNION ALL SELECT * FROM ratios
    UNION ALL SELECT * FROM growth
),
-- Fan the same resolved population out across both grouping levels.
-- `peer_group` carries whichever label applies, so every downstream
-- calculation is written once rather than duplicated per level.
levelled AS (
    SELECT r.*, 'sector'::TEXT AS peer_level, r.gics_sector AS peer_group
    FROM resolved_all r WHERE r.gics_sector IS NOT NULL
    UNION ALL
    SELECT r.*, 'sub_industry'::TEXT, r.gics_sub_industry
    FROM resolved_all r WHERE r.gics_sub_industry IS NOT NULL
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
    'from replayed history for all three indexes; the SP600 carries a '
    'documented hole from 2019-12 to 2021-02 where '
    'their history is replayed.';
COMMENT ON COLUMN sec_gold.peer_stats.peer_level IS
    'Which GICS level this row was scored against. Sector is the '
    'sounder default; sub_industry is finer but thin, and groups below '
    'five members are dropped entirely rather than degraded.';
COMMENT ON COLUMN sec_gold.peer_stats.zscore IS
    'Raw-value z-score: measures scale as much as performance. Prefer '
    'peer_percentile for size-skewed concepts, and treat both with '
    'suspicion when peer_count is small.';
