-- get_canonical(p_cik, p_concept, p_value_date, p_qtrs, p_mode)
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
-- Resolves a canonical concept to a single numeric value by walking
-- sec_gold.concept_tag_map in priority order. Industry-specific
-- entries (non-empty sic_prefix matching the company's SIC) beat
-- generic entries. The first matching tag with a non-null value for
-- the (cik, value_date, qtrs, rank) wins.
--
-- Mode:
--   'latest' → sec_silver.num_silver rank_latest=1 (restated, current)
--   'pit'    → sec_silver.num_silver rank_pit=1    (as-first-reported)

-- Resolution is two stages, deliberately split into two functions.
--
--   resolve_direct()  walks concept_tag_map only.
--   get_canonical()   returns that, or falls back to concept_formula.
--
-- Splitting them is what keeps formulas one level deep: the formula
-- branch calls resolve_direct on its operands, never get_canonical, so
-- a formula can never reference another formula. No recursion, no
-- cycles, no ordering problem, enforced by construction rather than by
-- convention.

DROP FUNCTION IF EXISTS sec_gold.resolve_direct(INTEGER, TEXT, DATE, INTEGER, TEXT);

CREATE FUNCTION sec_gold.resolve_direct(
    p_cik         INTEGER,
    p_concept     TEXT,
    p_value_date  DATE,
    p_qtrs        INTEGER DEFAULT 4,
    p_mode        TEXT    DEFAULT 'pit'
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT n.value * m.sign_multiplier
    FROM sec_gold.concept_tag_map m
    JOIN sec_silver.num_silver    n ON n.tag = m.tag
    LEFT JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
    WHERE m.concept = p_concept
      AND n.cik = p_cik
      AND n.value_date = p_value_date
      AND n.qtrs = p_qtrs
      AND n.segments IS NULL AND n.coreg IS NULL
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
      m.sic_prefix <> '' DESC,
      m.priority        ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.resolve_direct(INTEGER, TEXT, DATE, INTEGER, TEXT) IS
    'Tag-map walk only, no formula fallback. Operand resolver for '
    'derived concepts; most callers want get_canonical instead.';

DROP FUNCTION IF EXISTS sec_gold.get_canonical(INTEGER, TEXT, DATE, INTEGER, TEXT);

CREATE FUNCTION sec_gold.get_canonical(
    p_cik         INTEGER,
    p_concept     TEXT,
    p_value_date  DATE,
    p_qtrs        INTEGER DEFAULT 4,
    p_mode        TEXT    DEFAULT 'pit'
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        -- Direct tags always win. A company that files the concept
        -- outright should never be handed a reconstruction.
        sec_gold.resolve_direct(p_cik, p_concept, p_value_date, p_qtrs, p_mode),
        (
            SELECT CASE
                -- A required operand that did not resolve poisons the
                -- whole formula: gross profit from revenue alone is not
                -- gross profit.
                WHEN bool_or(f.required AND v.val IS NULL) THEN NULL
                -- Guard against a company that simply has none of the
                -- components returning a confident zero.
                WHEN count(v.val) = 0                     THEN NULL
                ELSE sum(f.coefficient * COALESCE(v.val, 0))
            END
            FROM sec_gold.concept_formula f
            CROSS JOIN LATERAL (
                SELECT sec_gold.resolve_direct(
                    p_cik, f.operand, p_value_date, p_qtrs, p_mode) AS val
            ) v
            WHERE f.concept = p_concept
        )
    );
$$;

COMMENT ON FUNCTION sec_gold.get_canonical(INTEGER, TEXT, DATE, INTEGER, TEXT) IS
    'Resolve a concept: direct tags first, then concept_formula. '
    'Returns NULL when a required operand is missing rather than a '
    'partial figure.';


-- get_canonical_by_ticker — convenience wrapper that accepts a ticker
CREATE OR REPLACE FUNCTION sec_gold.get_canonical_by_ticker(
    p_ticker      TEXT,
    p_concept     TEXT,
    p_value_date  DATE,
    p_qtrs        INTEGER DEFAULT 4,
    p_mode        TEXT    DEFAULT 'pit'
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT sec_gold.get_canonical(
        (SELECT cik FROM sec_silver.ticker_map WHERE ticker = sec_gold.norm_ticker(p_ticker)),
        p_concept, p_value_date, p_qtrs, p_mode
    );
$$;
