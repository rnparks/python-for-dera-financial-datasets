-- Fiscal-year-aware "latest annual" lookups.
--
-- Default mode is 'pit', not 'latest'. A caller who omits p_mode is
-- most often writing research code, and silently handing them restated
-- figures is the most damaging default available. 'latest' now requires
-- asking for it. Note that 'pit' is still not availability-correct:
-- it has no knowledge date. Use sec_gold.as_of_* for backtests.
--
-- TICKER RESOLUTION CAVEAT. The ticker-keyed functions below resolve
-- through `sec_silver.ticker_map`, which is SEC's CURRENT-STATE
-- crosswalk: it lists only companies registered with a ticker today, so
-- a ticker that has since been retired or reassigned does not resolve,
-- and a delisted company cannot be looked up by the symbol it traded
-- under. Measured on this data, today's file is missing 58.5% of 2013
-- filers.
--
-- The sibling matviews (030_tradable_financials, 035_fact_asof,
-- 056_share_class_shares) use `sec_reference.company_ticker`, which is
-- dated and survivorship-free. The split is historical, not intentional.
-- Anything doing research over past universes should resolve the CIK via
-- `sec_reference.cik_at(ticker, asof)` and call the CIK-keyed function.
--
-- The canonical filter `value_date = '2024-12-31' AND qtrs = 4` only
-- catches calendar-year filers. Companies with non-December fiscal
-- year ends (Apple → Sep, Nike → May, Microsoft → June, NVDA → Jan,
-- Oracle → May, Walmart → Jan, Disney → Sep, Paychex → May, …) never
-- show up in such queries and get silently dropped from screens.
--
-- latest_annual() takes a CIK and canonical concept and returns the
-- most recent annual observation regardless of when the company's
-- fiscal year ends. It branches on the concept's fact_type so that
-- income-statement and cash-flow items filter qtrs=4 (annual period
-- totals) while balance-sheet items filter qtrs=0 (point-in-time
-- snapshots). It honors the same mode parameter as get_canonical()
-- so backtests and fundamental analysis share one function family.
--
-- HOW A DERIVED CONCEPT IS RESOLVED, AND WHY THE NEWEST PERIOD WINS.
--
-- Two things were wrong in the previous version, both found by
-- measuring rather than reading:
--
--   1. The formula branch took its candidate periods only from operands
--      marked `required`. total_debt's two operands are both optional,
--      so it had NO candidate periods and never derived at all: 836 of
--      the 1,092 tracked companies that peer_stats resolves total_debt
--      for in FY2024 got NULL here.
--   2. It evaluated the formula at the single newest period where ANY
--      operand existed and gave up if the formula failed there, instead
--      of falling back to an older complete period. Five tracked
--      companies with a derivable FY2023 gross profit returned nothing.
--
-- And a third, a design choice that turned out to be wrong in practice:
-- "direct tags always win" was applied across periods, so Apple's
-- total_debt resolved to a 2015 LongTermDebt figure ($40.1B) while its
-- 2026 balance sheet carried the components ($82.7B). Now the direct hit
-- and the derived hit are each found at their own newest period, and
-- the newer period wins; a direct tag still beats a reconstruction of
-- the same period.

-- Explicit drop: CREATE OR REPLACE cannot change a RETURNS TABLE
-- shape, so editing this signature and re-applying the single file
-- against a live schema fails with "cannot change return type of
-- existing function". A full build-gold drops the schema first and
-- would not notice; the iteration loop does.
DROP FUNCTION IF EXISTS sec_gold.latest_annual(INTEGER, TEXT, TEXT);

CREATE OR REPLACE FUNCTION sec_gold.latest_annual(
    p_cik     INTEGER,
    p_concept TEXT,
    p_mode    TEXT DEFAULT 'pit'
) RETURNS TABLE (
    value_date  DATE,
    filed_date  DATE,
    value       NUMERIC,
    tag         TEXT
)
LANGUAGE sql STABLE AS $$
    -- A ratio or growth concept resolves through its base: the newest
    -- period at which the numerator (or the grown concept) resolves,
    -- direct or formula, then the denominator (or the prior year) at
    -- that same period. concept_ratio in 050 defines them.
    WITH target AS (
        SELECT COALESCE(r.numerator, x.c) AS concept, r.kind, r.denominator
        FROM (SELECT p_concept AS c) x
        LEFT JOIN sec_gold.concept_ratio r ON r.concept = x.c
    ),
    concept_type AS (
        SELECT CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END AS qtrs
        FROM target t JOIN sec_gold.canonical_concepts c ON c.concept = t.concept
    ),
    -- Direct tags: the newest period at which any mapped tag resolves,
    -- industry-specific rows first, then priority.
    direct_hit AS (
        SELECT
            n.value_date,
            n.filed_date,
            n.value * m.sign_multiplier AS value,
            n.tag
        FROM sec_gold.concept_tag_map m
        JOIN sec_silver.num_silver    n ON n.tag = m.tag
        LEFT JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
        CROSS JOIN concept_type ct
        WHERE m.concept = (SELECT concept FROM target)
          AND n.cik = p_cik
          AND n.qtrs = ct.qtrs
          AND n.segments IS NULL AND n.coreg IS NULL
          -- Same NULL-shadowing guard as get_canonical: a priority-1
          -- tag with no parseable value must not mask a valid
          -- lower-priority fallback.
          AND n.value IS NOT NULL
          AND (
              (p_mode = 'latest' AND n.rank_latest = 1)
           OR (p_mode = 'pit'    AND n.rank_pit    = 1)
          )
          AND (
              m.sic_prefix = ''
           OR s.sic::TEXT LIKE m.sic_prefix || '%'
          )
        ORDER BY
          n.value_date   DESC,        -- most recent fiscal year first
          m.sic_prefix <> '' DESC,    -- industry-specific beats generic
          m.priority     ASC
        LIMIT 1
    ),
    -- Formula: candidate periods are every period at which ANY operand
    -- resolves (required or not), newest first, bounded to the twelve
    -- most recent. The formula is evaluated at each until one succeeds,
    -- so a period missing a required operand falls through to the next
    -- rather than ending the search. Sourcing the dates from the
    -- operands keeps the components on the same statement: a gross
    -- profit assembled from this year's revenue and last year's cost
    -- would be worse than no answer at all.
    --
    -- Inlined rather than calling latest_annual recursively: a SQL
    -- function body is validated at CREATE time, so a self-reference
    -- fails outright on a fresh build, and inlining keeps the one-level
    -- rule visible here exactly as it is in get_canonical.
    derived_hit AS (
        SELECT x.value_date, x.filed_date, x.value, NULL::TEXT AS tag
        FROM (
            SELECT d.value_date, d.filed_date,
                   sec_gold.get_canonical(p_cik, (SELECT concept FROM target), d.value_date,
                                          ct.qtrs, p_mode) AS value
            FROM (
                SELECT n.value_date, MAX(n.filed_date) AS filed_date
                FROM sec_gold.concept_formula f
                JOIN sec_gold.concept_tag_map m ON m.concept = f.operand
                JOIN sec_silver.num_silver    n ON n.tag = m.tag
                LEFT JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
                CROSS JOIN concept_type ct
                WHERE f.concept = (SELECT concept FROM target)
                  AND n.cik = p_cik
                  AND n.qtrs = ct.qtrs
                  AND n.segments IS NULL AND n.coreg IS NULL
                  AND n.value IS NOT NULL
                  AND (
                      (p_mode = 'latest' AND n.rank_latest = 1)
                   OR (p_mode = 'pit'    AND n.rank_pit    = 1)
                  )
                  AND (m.sic_prefix = '' OR s.sic::TEXT LIKE m.sic_prefix || '%')
                GROUP BY n.value_date
                ORDER BY n.value_date DESC
                LIMIT 12
            ) d
            CROSS JOIN concept_type ct
        ) x
        WHERE x.value IS NOT NULL
        ORDER BY x.value_date DESC
        LIMIT 1
    )
    -- Newest period wins; at the same period a filed figure beats a
    -- reconstruction.
    , hit AS (
        SELECT u.value_date, u.filed_date, u.value, u.tag
        FROM (
            SELECT dh.value_date, dh.filed_date, dh.value, dh.tag, 0 AS pref FROM direct_hit  dh
            UNION ALL
            SELECT xh.value_date, xh.filed_date, xh.value, xh.tag, 1 AS pref FROM derived_hit xh
        ) u
        ORDER BY u.value_date DESC, u.pref ASC
        LIMIT 1
    )
    -- For a plain concept this is the hit itself. For a ratio the
    -- denominator is resolved at the hit's own period; for growth the
    -- base concept one year earlier (DERA rounds period ends to month
    -- end, so a year back lands on the prior fiscal year-end). A
    -- non-positive denominator or base gives NULL, not a number.
    SELECT h.value_date, h.filed_date,
           CASE t.kind
               WHEN 'ratio'  THEN CASE WHEN den.v   > 0 THEN h.value / den.v END
               WHEN 'growth' THEN CASE WHEN prior.v > 0 THEN (h.value - prior.v) / prior.v END
               ELSE h.value
           END AS value,
           CASE WHEN t.kind IS NULL THEN h.tag END AS tag
    FROM hit h
    CROSS JOIN target t
    CROSS JOIN concept_type ct
    LEFT JOIN LATERAL (
        SELECT sec_gold.get_canonical(
                   p_cik, t.denominator, h.value_date,
                   (SELECT CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
                      FROM sec_gold.canonical_concepts c WHERE c.concept = t.denominator),
                   p_mode) AS v
        WHERE t.kind = 'ratio'
    ) den ON TRUE
    LEFT JOIN LATERAL (
        SELECT sec_gold.get_canonical(
                   p_cik, t.concept, (h.value_date - INTERVAL '1 year')::date,
                   ct.qtrs, p_mode) AS v
        WHERE t.kind = 'growth'
    ) prior ON TRUE;
$$;


-- Convenience wrapper — ticker lookup
DROP FUNCTION IF EXISTS sec_gold.latest_annual_by_ticker(TEXT, TEXT, TEXT);

CREATE OR REPLACE FUNCTION sec_gold.latest_annual_by_ticker(
    p_ticker  TEXT,
    p_concept TEXT,
    p_mode    TEXT DEFAULT 'pit'
) RETURNS TABLE (
    value_date  DATE,
    filed_date  DATE,
    value       NUMERIC,
    tag         TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM sec_gold.latest_annual(
        (SELECT cik FROM sec_silver.ticker_map WHERE ticker = sec_gold.norm_ticker(p_ticker)),
        p_concept, p_mode
    );
$$;


-- Company snapshot — returns one row per canonical concept with the
-- most recent annual (or point-in-time) value. Derived concepts such as
-- free_cash_flow and total_debt are computed through concept_formula by
-- latest_annual, so they appear here with a value and a NULL tag.
DROP FUNCTION IF EXISTS sec_gold.company_snapshot(TEXT, TEXT);

CREATE OR REPLACE FUNCTION sec_gold.company_snapshot(
    p_ticker  TEXT,
    p_mode    TEXT DEFAULT 'pit'
) RETURNS TABLE (
    concept       TEXT,
    display_name  TEXT,
    fact_type     TEXT,
    value_date    DATE,
    value         NUMERIC,
    tag           TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT
        c.concept,
        c.display_name,
        c.fact_type,
        la.value_date,
        la.value,
        la.tag
    FROM sec_gold.canonical_concepts c
    LEFT JOIN LATERAL sec_gold.latest_annual_by_ticker(p_ticker, c.concept, p_mode) la ON TRUE
    ORDER BY c.concept;
$$;
