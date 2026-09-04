-- Default mode is 'pit', not 'latest'. A caller who omits p_mode is
-- most often writing research code, and silently handing them restated
-- figures is the most damaging default available. 'latest' now requires
-- asking for it. Note that 'pit' is still not availability-correct:
-- it has no knowledge date. Use sec_gold.as_of_* for backtests.
-- Fiscal-year-aware "latest annual" lookups.
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
    WITH concept_type AS (
        SELECT fact_type FROM sec_gold.canonical_concepts WHERE concept = p_concept
    ),
    resolved AS (
        SELECT
            n.value_date,
            n.filed_date,
            n.value * m.sign_multiplier AS value,
            n.tag,
            m.priority,
            m.sic_prefix
        FROM sec_gold.concept_tag_map m
        JOIN sec_silver.num_silver    n ON n.tag = m.tag
        LEFT JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
        CROSS JOIN concept_type ct
        WHERE m.concept = p_concept
          AND n.cik = p_cik
          AND n.qtrs = CASE WHEN ct.fact_type = 'balance' THEN 0 ELSE 4 END
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
    )
    SELECT r.value_date, r.filed_date, r.value, r.tag
    FROM resolved r
    ORDER BY
      r.value_date   DESC,            -- most recent fiscal year first
      r.sic_prefix <> '' DESC,        -- industry-specific beats generic
      r.priority     ASC
    LIMIT 1;
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
-- most recent annual (or point-in-time) value. Derived concepts like
-- free_cash_flow are excluded since they have no tag map entries;
-- clients compute them from the flow rows (operating_cash_flow
-- minus capex).
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
    WHERE c.fact_type <> 'derived'
    ORDER BY c.concept;
$$;
