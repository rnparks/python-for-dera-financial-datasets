-- Per-share-class share counts. The market-cap denominator.
--
-- Market cap for a multi-class issuer is the sum over classes of shares
-- times THAT CLASS'S price. A single collapsed count cannot produce it:
-- GOOGL and GOOG trade a percent or two apart, but BRK.A is roughly
-- 1,500 times BRK.B. `shares_outstanding_at` returns one number and is
-- therefore not sufficient here; this matview is.
--
-- THE CENTRAL DESIGN CHOICE: allowlist, not filter.
--
-- The obvious approach is to pattern-match the ClassOfStock axis and sum
-- what matches. That was tried and it is wrong. Against issuers that
-- publish both a consolidated total and clean per-class rows, summing
-- the classes disagreed with the total in 312 of 1,033 cases, because
-- the axis is free text whose members routinely overlap:
--
--   Symbotic  CommonClassA + CommonClassV1 + CommonClassV3 + CommonClassV1AndV3
--             the combined member overlaps the individual ones, sum is 82% high
--   Kodiak    CommonClassA + CommonClassANotSubjectToRedemption  (subset of parent)
--   Xanadu    ten members including a literal TotalCommonShares
--
-- No regex distinguishes those from genuine classes. So a class
-- contributes only if it is explicitly mapped in
-- sec_reference.share_class. An unmapped member produces nothing, which
-- makes the failures above structurally impossible rather than filtered
-- against. The cost is that a new multi-class issuer needs a mapping row
-- before it gets a market cap; the benefit is that it never gets a wrong
-- one.
--
-- THE SECOND DESIGN CHOICE: single-class is decided by the FILINGS, not
-- by counting tickers.
--
-- The first version inferred a single-class issuer from having exactly
-- one ticker with valid_to IS NULL, i.e. current today. Every company
-- that had delisted therefore had no rows at all: measured 2026-09-04,
-- 12,835 CIKs carried consolidated share counts and only 4,346 were
-- here, 4,998 of the rest excluded for no reason but having failed.
-- The second version required that no two ticker intervals overlap,
-- which fixed the delisted case but still excluded every company with a
-- listed preferred, baby bond or ADR line: 147 of the S&P 500 alone,
-- Bank of America with its seventeen tickers among them. And it quietly
-- ADMITTED dual-class issuers whose second class is unlisted -- Meta,
-- Nike, Visa -- pricing the consolidated count at the listed class on an
-- unverified 1:1 conversion (Visa's Class B does not convert 1:1).
--
-- The filings settle both. An issuer with two classes of common stock
-- reports its share counts per class on the ClassOfStock axis; an
-- issuer with one class and any number of preferreds does not. So:
--
--   single class  <=>  no share_class mapping AND at most one distinct
--                      single-axis ClassOfStock member on the two
--                      outstanding-share tags across its history
--
-- Measured on 2026-09-04: of the 147 excluded S&P 500 companies 136
-- have zero or one member and are recovered; the 35 with two or more are
-- precisely the dual-class issuers (Alphabet, Meta, Nike, Visa,
-- Mastercard, Comcast, ...) and need a cited mapping, which
-- tools/fetch_cover_page_classes.py derives from their own 10-K cover
-- pages. Across the whole spine the rule admits 2,547 companies and
-- withdraws 1,051 unmapped dual-class ones, which is the allowlist doing
-- its job. The price ticker is the PRIMARY ticker as of each fact's
-- availability date -- the spine marks one primary per overlapping run
-- and the common line is the primary -- with a flag saying whether it
-- was resolved as of the date.
--
-- POINT-IN-TIME COMES FREE. num_silver partitions its vintage chains by
-- `segments`, so every share class already has its own independent
-- known_at / tradable_from / superseded_tradable history. No new
-- availability logic is invented here, which is the main reason to build
-- on num_silver rather than on fact_asof (which filters segments IS NULL
-- and carries no segments column at all).

DROP MATERIALIZED VIEW IF EXISTS sec_gold.share_class_shares CASCADE;

CREATE MATERIALIZED VIEW sec_gold.share_class_shares AS
WITH share_facts AS (
    -- Every share-count fact, class-level and consolidated alike.
    -- Tag preference is expressed as `rung` and resolved per class
    -- below, so a class with a clean outstanding count is never
    -- represented by a weighted average. qtrs breaks ties between the
    -- period lengths a weighted average is reported over.
    SELECT
        n.cik,
        n.segments,
        n.value_date,
        n.qtrs,
        n.value,
        n.tag,
        n.known_at,
        n.tradable_from,
        n.superseded_tradable,
        n.vintage_seq,
        n.adsh,
        CASE n.tag
            WHEN 'EntityCommonStockSharesOutstanding'              THEN 1
            WHEN 'CommonStockSharesOutstanding'                    THEN 2
            WHEN 'CommonStockSharesIssued'                         THEN 3
            WHEN 'WeightedAverageNumberOfSharesOutstandingBasic'   THEN 8
            ELSE 9
        END AS rung
    FROM sec_silver.num_silver n
    WHERE n.uom = 'shares'
      AND n.coreg IS NULL
      AND n.value IS NOT NULL
      AND n.value > 0
      AND n.tag IN (
          'EntityCommonStockSharesOutstanding',
          'CommonStockSharesOutstanding',
          'CommonStockSharesIssued',
          'WeightedAverageNumberOfSharesOutstandingBasic'
      )
      AND n.value_date >= DATE '2008-01-01'
      AND n.value_date <= CURRENT_DATE + INTERVAL '1 year'
),
-- (1) Explicitly mapped classes. The allowlist join.
mapped AS (
    SELECT DISTINCT ON (f.cik, sc.class_label, f.value_date, f.vintage_seq)
        f.cik,
        sc.class_label,
        COALESCE(sc.ticker, sc.prices_with_ticker) AS price_ticker,
        TRUE                                       AS price_ticker_is_asof,
        (sc.ticker IS NULL)                        AS is_unlisted_class,
        COALESCE(sc.conversion_ratio, 1)           AS conversion_ratio,
        f.value                                    AS shares,
        f.value_date, f.known_at, f.tradable_from, f.superseded_tradable,
        f.vintage_seq, f.tag AS source_tag, f.rung, f.adsh,
        'mapped_class'::TEXT                       AS method,
        sc.source                                  AS mapping_source
    FROM share_facts f
    JOIN sec_reference.share_class sc
      ON sc.cik = f.cik
     -- Exact match on the SEC member string, prefix and trailing
     -- semicolon stripped. Deliberately not a LIKE: a fuzzy match here
     -- would readmit exactly the overlapping members this design exists
     -- to keep out.
     AND f.segments = 'ClassOfStock=' || sc.class_label || ';'
     AND NOT sc.is_excluded
     AND f.value_date >= sc.effective_from
     AND (sc.effective_to IS NULL OR f.value_date < sc.effective_to)
    ORDER BY f.cik, sc.class_label, f.value_date, f.vintage_seq, f.rung, f.qtrs
),
-- (2) Single-class issuers need no mapping: one class of common stock,
--     so the consolidated count IS the class count. Decided from the
--     filings (see the header): an issuer that has ever reported share
--     counts for two or more ClassOfStock members is dual-class and
--     needs a mapping; everyone else with a ticker history is here,
--     preferreds, notes and delistings notwithstanding.
-- Every single-axis ClassOfStock member an issuer has ever put a share
-- count under, on the three POINT-IN-TIME tags: Lennar and UPS report
-- per class only under CommonStockSharesIssued and would be invisible to
-- a test on the outstanding tags alone, while the weighted-average tag
-- carries junk members (General Motors files ClassOfStock=
-- EarningsPerShareBasic on it) that would flag single-class issuers.
share_members AS (
    SELECT cik, segments AS member
    FROM share_facts
    WHERE segments LIKE 'ClassOfStock=%'
      AND segments NOT LIKE '%;%;%'      -- single axis only
      AND rung <= 3
    GROUP BY cik, segments
),
multi_class AS (
    SELECT cik FROM share_members GROUP BY cik HAVING COUNT(*) >= 2
),
-- An issuer with exactly ONE member has one class; its member rows are
-- the consolidated count under another name (Bunge files
-- ClassOfStock=CommonStock and nothing undimensioned).
sole_member AS (
    SELECT cik, MIN(member) AS member FROM share_members GROUP BY cik HAVING COUNT(*) = 1
),
single_class AS (
    SELECT DISTINCT ct.cik
    FROM sec_reference.company_ticker ct
    WHERE NOT EXISTS (SELECT 1 FROM sec_reference.share_class sc WHERE sc.cik = ct.cik)
      AND NOT EXISTS (SELECT 1 FROM multi_class mc WHERE mc.cik = ct.cik)
),
inferred AS (
    SELECT DISTINCT ON (f.cik, f.value_date, f.vintage_seq)
        f.cik,
        '(single class)'::TEXT                 AS class_label,
        -- The ticker held on the fact's availability date, else the
        -- best-known symbol as a label. Same trade as tradable_financials:
        -- observed intervals start 2018-12, older facts get either the
        -- back-extended interval or the fallback, and the flag is TRUE
        -- only for an observed one.
        COALESCE(ct.ticker, cl.ticker_latest)  AS price_ticker,
        COALESCE(ct.source = 'observed', FALSE) AS price_ticker_is_asof,
        FALSE                                  AS is_unlisted_class,
        1::NUMERIC                             AS conversion_ratio,
        f.value                                AS shares,
        f.value_date, f.known_at, f.tradable_from, f.superseded_tradable,
        f.vintage_seq, f.tag AS source_tag, f.rung, f.adsh,
        'inferred_single'::TEXT                AS method,
        'inferred'::TEXT                       AS mapping_source
    FROM share_facts f
    JOIN single_class sc ON sc.cik = f.cik
    JOIN sec_reference.company_label cl ON cl.cik = f.cik
    -- Single-valued: exactly one PRIMARY interval covers any date (the
    -- spine marks one primary per overlapping run), and for a
    -- single-class issuer the primary is the common line -- the
    -- preferreds and notes are the non-primary ones.
    LEFT JOIN sec_reference.company_ticker ct
           ON ct.cik = f.cik
          AND ct.is_primary
          AND ct.valid_from <= f.tradable_from
          AND (ct.valid_to > f.tradable_from OR ct.valid_to IS NULL)
    LEFT JOIN sole_member sm ON sm.cik = f.cik
    WHERE f.segments IS NULL OR f.segments = sm.member   -- consolidated, or the one class
    ORDER BY f.cik, f.value_date, f.vintage_seq, f.rung, f.qtrs
)
SELECT m.*, co.name_latest AS company_name
FROM (SELECT * FROM mapped UNION ALL SELECT * FROM inferred) m
JOIN sec_reference.company co ON co.cik = m.cik;

CREATE INDEX idx_scs_cik      ON sec_gold.share_class_shares (cik, value_date);
CREATE INDEX idx_scs_ticker   ON sec_gold.share_class_shares (price_ticker, value_date);
-- The as-of interval scan, matching the shape used everywhere else.
CREATE INDEX idx_scs_asof     ON sec_gold.share_class_shares
    (cik, class_label, tradable_from, superseded_tradable);

COMMENT ON MATERIALIZED VIEW sec_gold.share_class_shares IS
    'Per-share-class share counts, the market-cap denominator. One row '
    'per (company, class, period, vintage, source tag). A class appears '
    'only if explicitly mapped in sec_reference.share_class, or if the '
    'issuer has never reported share counts for two ClassOfStock members '
    '(single class; preferreds, notes and delistings do not matter). '
    'Unmapped dual-class issuers contribute nothing, by design.';
COMMENT ON COLUMN sec_gold.share_class_shares.price_ticker IS
    'The ticker whose price applies to these shares. For an unlisted '
    'class this is the listed class it converts into, and '
    'is_unlisted_class is TRUE. For an inferred single-class issuer it '
    'is the ticker held on tradable_from when the crosswalk covers that '
    'date (price_ticker_is_asof), else the best-known symbol.';
COMMENT ON COLUMN sec_gold.share_class_shares.price_ticker_is_asof IS
    'TRUE when price_ticker was resolved as of this row''s own '
    'tradable_from (always TRUE for mapped classes, whose mapping is '
    'dated). FALSE means no observed interval (2018-12 onward) covers '
    'this fact and price_ticker is inferred: a back-extended '
    'single-ticker history or the company''s best-known symbol.';
COMMENT ON COLUMN sec_gold.share_class_shares.conversion_ratio IS
    'Shares of price_ticker per share of this class. Cited in the '
    'mapping source, never assumed.';
COMMENT ON COLUMN sec_gold.share_class_shares.rung IS
    'Tag preference: 1 EntityCommonStockSharesOutstanding, 2 '
    'CommonStockSharesOutstanding, 3 CommonStockSharesIssued, 8 weighted '
    'average. share_classes_at prefers the lower rung at a period.';

-- As-of accessor. Returns one row per class: the newest vintage that was
-- already actionable on the given date, preferring the better tag when
-- two tags carry the same period.
DROP FUNCTION IF EXISTS sec_gold.share_classes_at(INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.share_classes_at(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    class_label           TEXT,
    price_ticker          TEXT,
    is_unlisted_class     BOOLEAN,
    conversion_ratio      NUMERIC,
    shares                NUMERIC,
    value_date            DATE,
    tradable_from         DATE,
    source_tag            TEXT,
    method                TEXT,
    price_ticker_is_asof  BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (s.class_label)
           s.class_label, s.price_ticker, s.is_unlisted_class,
           s.conversion_ratio, s.shares, s.value_date, s.tradable_from,
           s.source_tag, s.method, s.price_ticker_is_asof
    FROM sec_gold.share_class_shares s,
         LATERAL (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d) k
    WHERE s.cik = p_cik
      AND s.tradable_from <= k.d
      AND (s.superseded_tradable > k.d OR s.superseded_tradable IS NULL)
    -- Most recent period first, so a class reported at several period
    -- ends resolves to the latest one knowable on the date; then the
    -- better tag; then the newest vintage.
    ORDER BY s.class_label, s.value_date DESC, s.rung ASC, s.vintage_seq DESC;
$$;

COMMENT ON FUNCTION sec_gold.share_classes_at(INTEGER, DATE, INTEGER) IS
    'Every share class for a company as knowable on p_asof, one row per '
    'class. Market cap is SUM(shares * price_of(price_ticker)); a class '
    'missing here means no mapping exists and market cap is incomplete.';
