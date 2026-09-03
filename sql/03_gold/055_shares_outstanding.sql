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
        SELECT n.tag, n.value, n.value_date, n.tradable_from, n.segments
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
               END AS rung
        FROM visible v
        WHERE v.segments IS NULL
    ),
    -- Sum the share classes only where no consolidated row exists for
    -- that tag and period.
    by_class AS (
        SELECT SUM(v.value) AS shares, v.value_date,
               MAX(v.tradable_from) AS tradable_from, v.tag AS source_tag,
               'class_sum'::TEXT AS method,
               CASE v.tag
                   WHEN 'CommonStockSharesOutstanding' THEN 4
                   WHEN 'CommonStockSharesIssued'      THEN 5
                   ELSE 9
               END AS rung
        FROM visible v
        WHERE v.segments LIKE 'ClassOfStock=%'
          AND v.segments NOT ILIKE '%treasury%'
          AND NOT EXISTS (
              SELECT 1 FROM consolidated c
              WHERE c.source_tag = v.tag AND c.value_date = v.value_date
          )
        GROUP BY v.value_date, v.tag
    )
    SELECT shares, value_date, tradable_from, source_tag, method
    FROM (
        SELECT * FROM consolidated
        UNION ALL
        SELECT * FROM by_class
    ) laddered
    WHERE shares > 0
    -- Most recent period first, then the most trustworthy rung.
    ORDER BY value_date DESC, rung ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER) IS
    'Share count knowable on p_asof, resolved by priority ladder with '
    'share-class summation. `method` says whether the figure came from '
    'a consolidated tag or a sum across classes; `source_tag` names the '
    'tag, so a weighted-average fallback is always visible.';
