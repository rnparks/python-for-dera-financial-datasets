-- Share counts, resolved through a priority ladder with share-class
-- summation.
--
-- Why this needs its own function rather than a concept_tag_map row:
-- concept_tag_map resolves one tag to one row, and the whole point here
-- is that a large minority of companies never publish a consolidated
-- share count. They tag only per share class, and the consolidated-only
-- filter used everywhere else in gold throws those rows away.
--
-- Measured coverage of the tracked universe for periods since 2024:
--
--   CommonStockSharesOutstanding, consolidated only     1,037   69.2%
--   plus summing across the share-class axis            1,167   77.9%
--   all five tags, class-summed, treasury excluded      1,490   99.5%
--
-- So the gap was never missing data. It was a tag choice plus a blanket
-- `segments IS NULL` filter.
--
-- Two traps this avoids:
--
-- 1. The largest segmented bucket is EquityComponents=CommonStock at
--    245,447 rows, which is the equity roll-forward dimension, not a
--    share class. Summing over every segment would double count.
--    Only ClassOfStock axes are summed, and treasury lines excluded.
--
-- 2. A company that publishes BOTH a consolidated total and per-class
--    rows must not have them added together. Alphabet reports 12.211B
--    consolidated alongside its class rows. The ladder therefore takes
--    the consolidated figure when present and only falls through to
--    summation when it is absent.
--
-- The weighted-average diluted count is a period average, not a
-- point-in-time count. It sits last and is reported with its source so
-- a caller can see when it was used rather than silently blending it
-- with instant counts.
--
-- RECENCY VERSUS KIND. The ladder used to order by value_date first and
-- rung second, so a period average with a newer period end beat a real
-- point-in-time count from the quarter before. Measured 2026-09-04:
-- 216 of 1,569 tracked companies resolved to a WeightedAverage* tag as
-- of today, and for 87 of them an instant count within 400 days
-- existed. Now an instant count within 400 days of the newest available
-- period beats an average at the newest period; only when no instant
-- count is that recent does the average win, and `source_tag` says so.

-- Explicit drop: CREATE OR REPLACE cannot change a RETURNS TABLE
-- shape, so editing this signature and re-applying the single file
-- against a live schema fails with "cannot change return type of
-- existing function". A full build-gold drops the schema first and
-- would not notice; the iteration loop does.
DROP FUNCTION IF EXISTS sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER);

CREATE OR REPLACE FUNCTION sec_gold.shares_outstanding_at(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    shares         NUMERIC,
    value_date     DATE,
    tradable_from  DATE,
    source_tag     TEXT,
    method         TEXT
)
LANGUAGE sql STABLE AS $$
    WITH k AS (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d),
    -- Every share-count fact knowable as of the date, including the
    -- per-class rows that the consolidated filter normally discards.
    visible AS (
        SELECT n.tag, n.value, n.value_date, n.tradable_from, n.segments, n.qtrs
        FROM sec_silver.num_silver n, k
        WHERE n.cik = p_cik
          AND n.coreg IS NULL
          AND n.value IS NOT NULL
          AND n.uom = 'shares'
          AND n.tag IN (
              'EntityCommonStockSharesOutstanding',
              'CommonStockSharesOutstanding',
              'CommonStockSharesIssued',
              'WeightedAverageNumberOfDilutedSharesOutstanding',
              'WeightedAverageNumberOfSharesOutstandingBasic'
          )
          AND n.tradable_from <= k.d
          AND (n.superseded_tradable > k.d OR n.superseded_tradable IS NULL)
    ),
    consolidated AS (
        SELECT v.value AS shares, v.value_date, v.tradable_from, v.tag AS source_tag,
               'consolidated'::TEXT AS method,
               CASE v.tag
                   WHEN 'EntityCommonStockSharesOutstanding'            THEN 1
                   WHEN 'CommonStockSharesOutstanding'                  THEN 2
                   WHEN 'CommonStockSharesIssued'                       THEN 3
                   WHEN 'WeightedAverageNumberOfDilutedSharesOutstanding' THEN 8
                   ELSE 9
               END AS rung,
               v.qtrs
        FROM visible v
        WHERE v.segments IS NULL
    ),
    -- Sum the share classes only where no consolidated row exists for
    -- that tag and period.
    --
    -- THE EQUIVALENT TRAP. Summing assumes the class rows are disjoint
    -- parts of one whole. For a handful of issuers they are not: they
    -- publish the SAME total twice, converted into each class's units.
    -- Berkshire is the case that exposed it:
    --
    --   ClassOfStock=EquivalentClassA        1,438,223
    --   ClassOfStock=EquivalentClassB    2,157,335,139
    --   ratio exactly 1500.0  (BRK.A converts to 1,500 BRK.B)
    --
    -- Adding those double counts the entire company. The error happened
    -- to be only 0.067% because A shares are tiny expressed in B units,
    -- which is precisely why it went unnoticed: it looked plausible and
    -- was wrong in principle. The A-equivalent row is now is_excluded in
    -- the mapping, so it never reaches the sum.
    by_class AS (
        SELECT
            -- Plain SUM is safe: only mapped classes reach here, and
            -- Berkshire's duplicate A-equivalent expression is marked
            -- is_excluded in the mapping rather than being detected by
            -- string matching.
            SUM(v.value) AS shares,
            v.value_date,
            MAX(v.tradable_from) AS tradable_from, v.tag AS source_tag,
            'class_sum_mapped'::TEXT AS method,
            CASE v.tag
                WHEN 'CommonStockSharesOutstanding' THEN 4
                WHEN 'CommonStockSharesIssued'      THEN 5
                ELSE 9
            END AS rung,
            MIN(v.qtrs) AS qtrs
        FROM visible v
        -- ALLOWLIST, not a pattern match. The previous filter was
        -- `segments LIKE 'ClassOfStock=%' AND NOT ILIKE '%treasury%'`,
        -- which had two defects found by testing rather than reading:
        --
        --   1. It matched ClassOfStock=SeriesAPreferredStock (97 issuers)
        --      and rows carrying a second axis such as
        --      SubsequentEventType or RelatedPartyTransaction (966
        --      issuers), summing non-common and non-class rows into a
        --      common share count. 78 tracked issuers were exposed.
        --   2. More fundamentally, summing class members is wrong in
        --      general: against issuers publishing both a consolidated
        --      total and clean per-class rows, the sum disagreed with the
        --      total in 312 of 1,033 cases, because the axis contains
        --      aggregates, subsets and duplicates of its own members.
        --
        -- No regex fixes (2). So the fallback sums only classes that
        -- sec_reference.share_class explicitly maps. Where an issuer has
        -- unmapped classes it yields nothing and the ladder falls back to
        -- a consolidated figure, which is the honest outcome.
        --
        -- sec_gold.share_class_shares is the correct object for anything
        -- needing per-class detail; this stays a single-number
        -- convenience.
        JOIN sec_reference.share_class sc
          ON sc.cik = p_cik
         AND v.segments = 'ClassOfStock=' || sc.class_label || ';'
         AND NOT sc.is_excluded
         AND v.value_date >= sc.effective_from
         AND (sc.effective_to IS NULL OR v.value_date < sc.effective_to)
        WHERE NOT EXISTS (
              SELECT 1 FROM consolidated c
              WHERE c.source_tag = v.tag AND c.value_date = v.value_date
          )
        GROUP BY v.value_date, v.tag
    ),
    laddered AS (
        SELECT l.*, MAX(l.value_date) OVER () AS newest_period
        FROM (
            SELECT * FROM consolidated
            UNION ALL
            SELECT * FROM by_class
        ) l
        WHERE l.shares > 0
    )
    SELECT shares, value_date, tradable_from, source_tag, method
    FROM laddered
    -- An instant count (rungs 1-5) within 400 days of the newest period
    -- first; then the most recent period, the most trustworthy rung, and
    -- the shortest period for an average (qtrs 1 is closer to a point in
    -- time than qtrs 4).
    ORDER BY (rung <= 5 AND value_date >= newest_period - 400) DESC,
             value_date DESC,
             rung ASC,
             qtrs ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER) IS
    'Share count knowable on p_asof, by priority ladder with mapped '
    'share-class summation. method: consolidated | class_sum_mapped. '
    'An instant count within 400 days of the newest period beats a '
    'weighted average. NOT sufficient for market cap on multi-class '
    'issuers - that needs each class priced separately (177 of 1,569 '
    'tracked companies hold more than one listed ticker, 2026-09-04); '
    'use share_classes_at.';
