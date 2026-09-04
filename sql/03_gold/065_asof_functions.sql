-- As-of accessors. The knowledge date has NO default anywhere in this
-- file, deliberately: omitting it must be a call-site error, not a
-- silent look-ahead. Every other accessor in gold defaults to something
-- convenient, and that is exactly how a backtest quietly reads the
-- future.
--
-- Numbered 065 rather than 045 because these resolve canonical
-- concepts, and concept_tag_map / canonical_concepts are not created
-- until 050. run_sql_dir executes a directory in lexical order, so an
-- earlier number fails outright on a fresh build.
--
-- p_buffer_sessions is the safety margin, expressed in trading sessions
-- rather than calendar days so a Friday close plus one lands on Monday.
-- It defaults to 0, meaning "the earliest session an investor could
-- genuinely have acted". Re-run a strategy at 1, 2 and 5 to see how
-- fast the edge decays; one that dies at a single extra session was
-- never an edge.
--
-- TICKER WRAPPERS RAISE ON AN UNRESOLVABLE TICKER. Observed crosswalk
-- intervals start 2018-12; before the back-extension in 05_spine/010,
-- sec_reference.cik_at('AAPL', DATE '2015-06-30') was NULL. The
-- wrappers used to pass that NULL straight through, and the README's
-- own headline example returned fifteen rows with no values and no
-- message. They now resolve through cik_at_strict(), which raises, and
-- CIK-keyed overloads exist for dates the crosswalk still cannot reach
-- (a ticker that changed before 2019, or a company the file never
-- carried).

-- ---------------------------------------------------------------
-- Every fact for one company as it stood on a given date.
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS sec_gold.as_of_facts(INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_facts(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    tag            TEXT,
    metric         TEXT,
    value_date     DATE,
    qtrs           INTEGER,
    uom            TEXT,
    value          NUMERIC,
    adsh           TEXT,
    filed_date     DATE,
    known_at       TIMESTAMPTZ,
    tradable_from  DATE,
    vintage_seq    BIGINT,
    is_original_disclosure BOOLEAN
)
LANGUAGE sql STABLE AS $$
    SELECT f.tag, f.metric, f.value_date, f.qtrs, f.uom, f.value,
           f.adsh, f.filed_date, f.known_at, f.tradable_from,
           f.vintage_seq, f.is_original_disclosure
    FROM sec_gold.fact_asof f,
         LATERAL (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d) k
    WHERE f.cik = p_cik
      AND f.tradable_from <= k.d
      AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL);
$$;

-- ---------------------------------------------------------------
-- One canonical concept for one company/period, as of a date.
-- ---------------------------------------------------------------
-- Same two-stage split as get_canonical: a direct tag walk, then a
-- formula fallback that calls the direct resolver on its operands. The
-- availability predicate lives in the direct function only, so every
-- operand of a derived concept is filtered by the same knowledge date
-- and a formula can never mix vintages.
DROP FUNCTION IF EXISTS sec_gold.as_of_resolve_direct(INTEGER, TEXT, DATE, INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_resolve_direct(
    p_cik              INTEGER,
    p_concept          TEXT,
    p_value_date       DATE,
    p_qtrs             INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT f.value * m.sign_multiplier
    FROM sec_gold.concept_tag_map m
    JOIN sec_gold.fact_asof      f ON f.tag = m.tag
    LEFT JOIN sec_reference.company c ON c.cik = f.cik,
    LATERAL (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d) k
    WHERE m.concept = p_concept
      AND f.cik = p_cik
      AND f.value_date = p_value_date
      AND f.qtrs = p_qtrs
      AND f.value IS NOT NULL
      AND f.tradable_from <= k.d
      AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL)
      AND (m.sic_prefix = '' OR c.sic_latest::TEXT LIKE m.sic_prefix || '%')
    ORDER BY m.sic_prefix <> '' DESC, m.priority ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.as_of_resolve_direct(INTEGER, TEXT, DATE, INTEGER, DATE, INTEGER) IS
    'Tag-map walk against fact_asof, no formula fallback. Operand '
    'resolver for derived concepts; callers want as_of_canonical.';

DROP FUNCTION IF EXISTS sec_gold.as_of_canonical(INTEGER, TEXT, DATE, INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_canonical(
    p_cik              INTEGER,
    p_concept          TEXT,
    p_value_date       DATE,
    p_qtrs             INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        sec_gold.as_of_resolve_direct(
            p_cik, p_concept, p_value_date, p_qtrs, p_asof, p_buffer_sessions),
        (
            SELECT CASE
                WHEN bool_or(fm.required AND v.val IS NULL) THEN NULL
                WHEN count(v.val) = 0                       THEN NULL
                ELSE sum(fm.coefficient * COALESCE(v.val, 0))
            END
            FROM sec_gold.concept_formula fm
            CROSS JOIN LATERAL (
                SELECT sec_gold.as_of_resolve_direct(
                    p_cik, fm.operand, p_value_date, p_qtrs,
                    p_asof, p_buffer_sessions) AS val
            ) v
            WHERE fm.concept = p_concept
        )
    );
$$;

COMMENT ON FUNCTION sec_gold.as_of_canonical(INTEGER, TEXT, DATE, INTEGER, DATE, INTEGER) IS
    'Concept value knowable on p_asof: direct tags first, then '
    'concept_formula. Every operand is filtered by the same knowledge '
    'date, so a derived value never mixes vintages.';

-- ---------------------------------------------------------------
-- Most recent annual observation as of a date, fiscal-year aware.
-- ---------------------------------------------------------------
-- Mirrors latest_annual() in 070_fiscal_year_views.sql, against
-- fact_asof with the availability predicate, and with the same formula
-- fallback. It had none: as_of_snapshot returned free_cash_flow for 0
-- of 148 tracked tickers where company_snapshot returned it for all
-- 148, and Apple's as-of total_debt was a 2015 LongTermDebt figure with
-- the 2026 components sitting unused. The candidate periods for the
-- formula come from any operand visible as of the date, newest first,
-- and as_of_canonical evaluates each so every operand shares one
-- knowledge date. The newest period wins; a filed figure beats a
-- reconstruction of the same period.
DROP FUNCTION IF EXISTS sec_gold.as_of_latest_annual(INTEGER, TEXT, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_latest_annual(
    p_cik              INTEGER,
    p_concept          TEXT,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    value_date     DATE,
    tradable_from  DATE,
    value          NUMERIC,
    tag            TEXT
)
LANGUAGE sql STABLE AS $$
    WITH concept_type AS (
        SELECT CASE WHEN fact_type = 'balance' THEN 0 ELSE 4 END AS qtrs
        FROM sec_gold.canonical_concepts WHERE concept = p_concept
    ),
    k AS (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d),
    direct_hit AS (
        SELECT f.value_date, f.tradable_from, f.value * m.sign_multiplier AS value, f.tag
        FROM sec_gold.concept_tag_map m
        JOIN sec_gold.fact_asof      f ON f.tag = m.tag
        LEFT JOIN sec_reference.company c ON c.cik = f.cik
        CROSS JOIN concept_type ct
        CROSS JOIN k
        WHERE m.concept = p_concept
          AND f.cik = p_cik
          AND f.qtrs = ct.qtrs
          AND f.value IS NOT NULL
          AND f.tradable_from <= k.d
          AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL)
          AND (m.sic_prefix = '' OR c.sic_latest::TEXT LIKE m.sic_prefix || '%')
        ORDER BY f.value_date DESC,
                 m.sic_prefix <> '' DESC,
                 m.priority ASC
        LIMIT 1
    ),
    derived_hit AS (
        SELECT x.value_date, x.tradable_from, x.value, NULL::TEXT AS tag
        FROM (
            SELECT d.value_date, d.tradable_from,
                   sec_gold.as_of_canonical(p_cik, p_concept, d.value_date,
                                            ct.qtrs, p_asof, p_buffer_sessions) AS value
            FROM (
                -- tradable_from of the derived figure is the moment its
                -- last operand became actionable.
                SELECT f.value_date, MAX(f.tradable_from) AS tradable_from
                FROM sec_gold.concept_formula fm
                JOIN sec_gold.concept_tag_map m ON m.concept = fm.operand
                JOIN sec_gold.fact_asof      f ON f.tag = m.tag
                LEFT JOIN sec_reference.company c ON c.cik = f.cik
                CROSS JOIN concept_type ct
                CROSS JOIN k
                WHERE fm.concept = p_concept
                  AND f.cik = p_cik
                  AND f.qtrs = ct.qtrs
                  AND f.value IS NOT NULL
                  AND f.tradable_from <= k.d
                  AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL)
                  AND (m.sic_prefix = '' OR c.sic_latest::TEXT LIKE m.sic_prefix || '%')
                GROUP BY f.value_date
                ORDER BY f.value_date DESC
                LIMIT 12
            ) d
            CROSS JOIN concept_type ct
        ) x
        WHERE x.value IS NOT NULL
        ORDER BY x.value_date DESC
        LIMIT 1
    )
    SELECT u.value_date, u.tradable_from, u.value, u.tag
    FROM (
        SELECT dh.value_date, dh.tradable_from, dh.value, dh.tag, 0 AS pref FROM direct_hit  dh
        UNION ALL
        SELECT xh.value_date, xh.tradable_from, xh.value, xh.tag, 1 AS pref FROM derived_hit xh
    ) u
    ORDER BY u.value_date DESC, u.pref ASC
    LIMIT 1;
$$;

-- ---------------------------------------------------------------
-- Ticker wrappers. The ticker is resolved AS OF the same date, because
-- symbols are recycled between unrelated companies, and STRICTLY,
-- because an unresolvable ticker must be an error rather than a NULL
-- CIK that quietly matches nothing.
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS sec_gold.as_of_latest_annual_by_ticker(TEXT, TEXT, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_latest_annual_by_ticker(
    p_ticker           TEXT,
    p_concept          TEXT,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    value_date     DATE,
    tradable_from  DATE,
    value          NUMERIC,
    tag            TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM sec_gold.as_of_latest_annual(
        sec_reference.cik_at_strict(p_ticker, p_asof),
        p_concept, p_asof, p_buffer_sessions
    );
$$;

-- ---------------------------------------------------------------
-- Whole-company snapshot as of a date. Two overloads: by CIK, which
-- works at any date, and by ticker, which resolves the CIK as of the
-- same date and raises when the crosswalk cannot.
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS sec_gold.as_of_snapshot(INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_snapshot(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept        TEXT,
    display_name   TEXT,
    fact_type      TEXT,
    value_date     DATE,
    tradable_from  DATE,
    value          NUMERIC,
    tag            TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT c.concept, c.display_name, c.fact_type,
           la.value_date, la.tradable_from, la.value, la.tag
    FROM sec_gold.canonical_concepts c
    LEFT JOIN LATERAL sec_gold.as_of_latest_annual(
        p_cik, c.concept, p_asof, p_buffer_sessions
    ) la ON TRUE
    ORDER BY c.concept;
$$;

COMMENT ON FUNCTION sec_gold.as_of_snapshot(INTEGER, DATE, INTEGER) IS
    'Every canonical concept for a company (by CIK) as it was knowable '
    'on p_asof. The knowledge date is required, by design. Works at any '
    'date, including where no crosswalk interval exists.';

DROP FUNCTION IF EXISTS sec_gold.as_of_snapshot(TEXT, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_snapshot(
    p_ticker           TEXT,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept        TEXT,
    display_name   TEXT,
    fact_type      TEXT,
    value_date     DATE,
    tradable_from  DATE,
    value          NUMERIC,
    tag            TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM sec_gold.as_of_snapshot(
        sec_reference.cik_at_strict(p_ticker, p_asof),
        p_asof, p_buffer_sessions
    );
$$;

COMMENT ON FUNCTION sec_gold.as_of_snapshot(TEXT, DATE, INTEGER) IS
    'Every canonical concept for a ticker as it was knowable on p_asof. '
    'The ticker is resolved as of the same date and the call raises if '
    'the crosswalk cannot resolve it (observed from 2018-12, extended '
    'earlier for single-ticker histories); use the CIK overload then.';
