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
-- convention. A formula has variants (concept_formula_variant), tried
-- in order with an industry scope and a custom-line guard each; see
-- 050 for the rule and the measurements behind it.

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
      -- Dollars only. Berkshire files its euro, sterling and yen notes
      -- as undimensioned DebtAndCapitalLeaseObligations rows in those
      -- currencies, and total_debt resolved to whichever the tie-break
      -- picked: 1.26 trillion yen for FY2023, read as dollars (found
      -- 2026-09-11). DERA records per-share values in USD as well.
      AND n.uom = 'USD'
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

-- The guard behind a formula variant: does the filer carry, at this
-- date, a plain balance under a company-extension tag whose name says
-- debt? A tag is custom when no version of it is us-gaap. See the
-- variant table in 050 for why this exists.
DROP FUNCTION IF EXISTS sec_gold.custom_line_present(INTEGER, DATE, TEXT, TEXT, TEXT);

CREATE FUNCTION sec_gold.custom_line_present(
    p_cik         INTEGER,
    p_value_date  DATE,
    p_match       TEXT,
    p_except      TEXT,
    p_mode        TEXT DEFAULT 'pit'
) RETURNS BOOLEAN
LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1
        FROM sec_silver.num_silver n
        WHERE n.cik = p_cik
          AND n.value_date = p_value_date
          AND n.qtrs = 0
          AND n.segments IS NULL AND n.coreg IS NULL
          AND n.value > 0
          AND (
              (p_mode = 'latest' AND n.rank_latest = 1)
           OR (p_mode = 'pit'    AND n.rank_pit    = 1)
          )
          AND n.tag ~ p_match
          AND (p_except IS NULL OR n.tag !~ p_except)
          AND NOT EXISTS (SELECT 1 FROM sec_silver.tag_silver t
                           WHERE t.tag = n.tag AND t.version LIKE 'us-gaap%')
    );
$$;

COMMENT ON FUNCTION sec_gold.custom_line_present(INTEGER, DATE, TEXT, TEXT, TEXT) IS
    'TRUE when the filer has a positive, undimensioned balance at the date '
    'under a custom-namespace tag matching p_match and not p_except. The '
    'guard of a concept_formula_variant.';

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
            -- Then the formula variants, in order; the first that
            -- resolves wins. A variant is skipped outside its industries
            -- or when its guard finds a custom debt line at the date.
            SELECT v.total
            FROM sec_gold.concept_formula_variant fv
            LEFT JOIN sec_reference.company co ON co.cik = p_cik
            CROSS JOIN LATERAL (
                SELECT CASE
                    -- A required operand that did not resolve poisons the
                    -- whole variant: gross profit from revenue alone is not
                    -- gross profit.
                    WHEN bool_or(f.required AND o.val IS NULL) THEN NULL
                    -- Guard against a company that simply has none of the
                    -- components returning a confident zero.
                    WHEN count(o.val) = 0                     THEN NULL
                    ELSE sum(f.coefficient * COALESCE(o.val, 0))
                END AS total
                FROM sec_gold.concept_formula f
                CROSS JOIN LATERAL (
                    SELECT sec_gold.resolve_direct(
                        p_cik, f.operand, p_value_date, p_qtrs, p_mode) AS val
                ) o
                WHERE f.concept = fv.concept AND f.variant = fv.variant
            ) v
            WHERE fv.concept = p_concept
              AND (cardinality(fv.sic_prefixes) = 0
                   OR EXISTS (SELECT 1 FROM unnest(fv.sic_prefixes) sp
                               WHERE co.sic_latest::TEXT LIKE sp || '%'))
              AND (fv.guard_match IS NULL
                   OR NOT sec_gold.custom_line_present(
                          p_cik, p_value_date, fv.guard_match, fv.guard_except, p_mode))
              AND v.total IS NOT NULL
            ORDER BY fv.variant
            LIMIT 1
        )
    );
$$;

COMMENT ON FUNCTION sec_gold.get_canonical(INTEGER, TEXT, DATE, INTEGER, TEXT) IS
    'Resolve a concept: direct tags first, then the concept_formula '
    'variants in order. Returns NULL when a required operand is missing '
    'rather than a partial figure.';


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
