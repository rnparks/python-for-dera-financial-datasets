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
    -- was wrong in principle.
    --
    -- So the aggregate branches on the label. Where the segments say
    -- "Equivalent" the rows are alternative expressions of one total and
    -- the largest is taken, that being the finest unit. Everywhere else
    -- they are genuine separate classes and are summed. `method`
    -- records which, because the two mean different things to a caller
    -- computing market cap.
    by_class AS (
        SELECT
            CASE WHEN bool_or(v.segments ILIKE '%Equivalent%')
                 THEN MAX(v.value)
                 ELSE SUM(v.value)
            END AS shares,
            v.value_date,
            MAX(v.tradable_from) AS tradable_from, v.tag AS source_tag,
            CASE WHEN bool_or(v.segments ILIKE '%Equivalent%')
                 THEN 'class_equivalent'::TEXT
                 ELSE 'class_sum'::TEXT
            END AS method,
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
    'Share count knowable on p_asof, by priority ladder with share-class '
    'handling. method: consolidated | class_sum | class_equivalent. '
    'NOT sufficient for market cap on multi-class issuers - that needs '
    'each class priced separately, and 329 of 1,504 issuers have more '
    'than one class.';
