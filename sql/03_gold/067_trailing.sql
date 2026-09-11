-- Quarterly flows and trailing twelve months, computed on demand.
--
-- Nothing here is stored. Ryan's constraint (2026-09-11): the database
-- is large enough; a slower answer beats a bigger table. Every function
-- in this file reads sec_gold.fact_asof for one company and returns.
--
-- WHAT DERA GIVES US, MEASURED ON THE S&P 500'S 2024 QUARTER-ENDS.
-- Income-statement items come as a three-month value (qtrs = 1) at Q1,
-- Q2 and Q3 and as the year-to-date value (qtrs = 2, 3) at Q2 and Q3;
-- the 10-K carries the year (qtrs = 4) and never a fourth-quarter
-- figure (NetIncomeLoss: 1,421 three-month company-quarters against 465
-- annual). Cash-flow items come year-to-date only: a three-month
-- operating cash flow exists at Q1 alone (521 against 1,421). So a
-- quarter is what the filer printed when it printed one, else the
-- difference of two consecutive year-to-date figures: Apple's Q4 FY2024
-- revenue is 391.035B - 296.105B = 94.930B, its Q3 operating cash flow
-- 91.443B - 62.585B = 28.858B. A filed three-month figure beats the
-- difference at the same date, as a filed value beats a reconstruction
-- everywhere in gold.
--
-- Trailing twelve months at a quarter-end is the annual figure when the
-- quarter-end is the fiscal year-end, else the prior fiscal year plus
-- the current year-to-date less the prior year's year-to-date to the
-- same quarter (the 10-Q carries that comparative): Apple at 2024-06-30
-- is 383.285 + 296.105 - 293.787 = 385.603B. When a comparative is
-- missing the four derived quarters are summed instead, and the row
-- says which (ttm_source). Growth is against the quarter before (qoq),
-- the same quarter a year earlier (yoy) and the trailing twelve months
-- a year earlier; a non-positive base is NULL, never a number, as in
-- concept_ratio. Diluted EPS follows the same arithmetic, which is the
-- market convention for a trailing EPS, not a recomputation from
-- trailing shares.
--
-- Periods are matched by date windows rather than a fiscal calendar:
-- the quarter before ends 70 to 110 days earlier, the year before 345 to
-- 385 days earlier. That tolerates 52/53-week years and DERA's rounding
-- of period ends to month-end; a change of fiscal year-end leaves NULLs
-- rather than a wrong comparison.
--
-- Point in time. as_of_quarterly and as_of_trailing take the knowledge
-- date, with no default, like the rest of the as_of_* family (065);
-- every figure comes from the vintage of each fact that was actionable
-- on that date, and tradable_from is the latest of the components'. The
-- convenience forms quarterly(cik) and trailing(cik) are the same as of
-- today, which is the latest restated vintage of everything filed.
--
-- Runs after 065 (shift_sessions, the as-of predicate it copies) and
-- 050 (concept_tag_map, concept_formula). Flow concepts only; a balance
-- has no quarter and no trailing sum.

DROP FUNCTION IF EXISTS sec_gold.as_of_quarterly(INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_quarterly(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_prior_end      DATE,
    q_prior_value    NUMERIC,
    qoq_growth       NUMERIC,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_growth       NUMERIC,
    ttm_value        NUMERIC,
    ttm_source       TEXT,
    ttm_tradable_from DATE,
    ttm_prior_value  NUMERIC,
    ttm_growth       NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH k AS (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d),
    -- The company's period facts that were actionable on the knowledge
    -- date, read once through the (cik, tag, ...) index. Materialized so
    -- the planner does not go in by tag: joined to the tag map first it
    -- bitmap-scanned 288,000 rows per tag (1.6 s for Apple; 60 ms this way).
    company_facts AS MATERIALIZED (
        SELECT f.tag, f.value_date, f.qtrs, f.value, f.tradable_from
        FROM sec_gold.fact_asof f
        CROSS JOIN k
        WHERE f.cik = p_cik
          AND f.qtrs BETWEEN 1 AND 4
          AND f.uom = 'USD'
          AND f.value IS NOT NULL
          AND f.tradable_from <= k.d
          AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL)
    ),
    -- Those under the tags the concept map knows for a flow concept.
    facts AS (
        SELECT m.concept, f.value_date, f.qtrs, f.value * m.sign_multiplier AS value,
               f.tradable_from, m.sic_prefix, m.priority
        FROM sec_gold.concept_tag_map m
        JOIN sec_gold.canonical_concepts cc ON cc.concept = m.concept AND cc.fact_type = 'flow'
        JOIN company_facts f ON f.tag = m.tag
        LEFT JOIN sec_reference.company c ON c.cik = p_cik
        WHERE (m.sic_prefix = '' OR c.sic_latest::TEXT LIKE m.sic_prefix || '%')
    ),
    -- One value per (concept, period end, period length): the industry
    -- rule first, then priority, exactly as the direct resolvers walk.
    direct AS (
        SELECT DISTINCT ON (concept, value_date, qtrs)
               concept, value_date, qtrs, value, tradable_from
        FROM facts
        ORDER BY concept, value_date, qtrs, sic_prefix <> '' DESC, priority ASC
    ),
    -- A formula concept (gross_profit, free_cash_flow) at a period where
    -- no tag resolved it, from operands that share the period; a
    -- required operand missing means no value.
    derived AS (
        SELECT fm.concept, o.value_date, o.qtrs,
               SUM(fm.coefficient * o.value) AS value,
               MAX(o.tradable_from) AS tradable_from
        FROM sec_gold.concept_formula fm
        JOIN sec_gold.canonical_concepts cc ON cc.concept = fm.concept AND cc.fact_type IN ('flow', 'derived')
        JOIN direct o ON o.concept = fm.operand
        WHERE fm.variant = 1
        GROUP BY fm.concept, o.value_date, o.qtrs
        HAVING NOT EXISTS (
            SELECT 1 FROM sec_gold.concept_formula r
            WHERE r.concept = fm.concept AND r.variant = 1 AND r.required
              AND r.operand NOT IN (SELECT o2.concept FROM direct o2
                                    WHERE o2.value_date = o.value_date AND o2.qtrs = o.qtrs)
        )
        AND NOT EXISTS (SELECT 1 FROM direct d WHERE d.concept = fm.concept
                          AND d.value_date = o.value_date AND d.qtrs = o.qtrs)
    ),
    period AS (
        SELECT concept, value_date, qtrs, value, tradable_from FROM direct
        UNION ALL
        SELECT concept, value_date, qtrs, value, tradable_from FROM derived
    ),
    -- The fiscal quarter a period end is: the longest period the company
    -- reported ending there, across all flow concepts.
    grid AS (
        SELECT value_date, MAX(qtrs) AS fiscal_quarter FROM period GROUP BY value_date
    ),
    -- A quarter: the filed three-month value, else this period's
    -- year-to-date less the year-to-date one quarter shorter that ended
    -- a quarter earlier.
    quarter_candidates AS (
        SELECT p.concept, p.value_date AS quarter_end, p.value AS q_value, 'reported'::TEXT AS q_source,
               p.tradable_from, 0 AS pref
        FROM period p
        WHERE p.qtrs = 1
        UNION ALL
        SELECT p.concept, p.value_date, p.value - q.value, 'ytd_difference', GREATEST(p.tradable_from, q.tradable_from), 1
        FROM period p
        JOIN period q ON q.concept = p.concept AND q.qtrs = p.qtrs - 1
                     AND q.value_date BETWEEN p.value_date - 110 AND p.value_date - 70
        WHERE p.qtrs BETWEEN 2 AND 4
    ),
    quarters AS (
        SELECT DISTINCT ON (concept, quarter_end)
               concept, quarter_end, q_value, q_source, tradable_from
        FROM quarter_candidates
        ORDER BY concept, quarter_end, pref
    ),
    -- Trailing twelve months: the annual figure at a fiscal year-end;
    -- else prior year + year-to-date - prior year's year-to-date to the
    -- same quarter; else the sum of four consecutive quarters.
    ttm_candidates AS (
        SELECT p.concept, p.value_date AS quarter_end, p.value AS ttm_value, 'annual'::TEXT AS ttm_source,
               p.tradable_from, 0 AS pref
        FROM period p WHERE p.qtrs = 4
        UNION ALL
        -- Over the year-to-date rows only (the period as long as the
        -- fiscal quarter is: a three-month figure at Q2 is not one), the
        -- prior year's year-to-date to the same quarter is the row before
        -- in the (concept, qtrs) series and the prior fiscal year is the
        -- last annual row before this one. Windows and one equality join,
        -- because a join of three date windows over the period rows ran a
        -- second per company on nested loops.
        SELECT c.concept, c.value_date, fy.value + c.value - c.py_value, 'annual_plus_ytd',
               GREATEST(fy.tradable_from, c.tradable_from, c.py_tradable_from), 1
        FROM (
            SELECT p.*,
                   LAG(p.value_date)    OVER (PARTITION BY p.concept, p.qtrs ORDER BY p.value_date) AS py_date,
                   LAG(p.value)         OVER (PARTITION BY p.concept, p.qtrs ORDER BY p.value_date) AS py_value,
                   LAG(p.tradable_from) OVER (PARTITION BY p.concept, p.qtrs ORDER BY p.value_date) AS py_tradable_from,
                   MAX(CASE WHEN p.qtrs = 4 THEN p.value_date END)
                       OVER (PARTITION BY p.concept ORDER BY p.value_date
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS fy_date
            FROM period p
            JOIN grid g ON g.value_date = p.value_date AND g.fiscal_quarter = p.qtrs
        ) c
        JOIN period fy ON fy.concept = c.concept AND fy.qtrs = 4 AND fy.value_date = c.fy_date
        WHERE c.qtrs BETWEEN 1 AND 3
          AND c.py_date BETWEEN c.value_date - 385 AND c.value_date - 345
          AND c.fy_date BETWEEN c.value_date - (c.qtrs * 91 + 25) AND c.value_date - (c.qtrs * 91 - 25)
        UNION ALL
        -- Four consecutive quarters, each 70 to 110 days after the one
        -- before. Window lags, not a four-way self-join: the join ran 1.3 s
        -- on Apple's 580 quarters, this runs in a few milliseconds.
        SELECT concept, quarter_end, q_value + v1 + v2 + v3, 'four_quarters',
               GREATEST(tradable_from, t1, t2, t3), 2
        FROM (
            SELECT concept, quarter_end, q_value, tradable_from,
                   LAG(quarter_end, 1) OVER w AS e1, LAG(q_value, 1) OVER w AS v1, LAG(tradable_from, 1) OVER w AS t1,
                   LAG(quarter_end, 2) OVER w AS e2, LAG(q_value, 2) OVER w AS v2, LAG(tradable_from, 2) OVER w AS t2,
                   LAG(quarter_end, 3) OVER w AS e3, LAG(q_value, 3) OVER w AS v3, LAG(tradable_from, 3) OVER w AS t3
            FROM quarters
            WINDOW w AS (PARTITION BY concept ORDER BY quarter_end)
        ) l
        WHERE e1 BETWEEN quarter_end - 110 AND quarter_end - 70
          AND e2 BETWEEN e1 - 110 AND e1 - 70
          AND e3 BETWEEN e2 - 110 AND e2 - 70
    ),
    ttm AS (
        SELECT DISTINCT ON (concept, quarter_end)
               concept, quarter_end, ttm_value, ttm_source, tradable_from
        FROM ttm_candidates
        ORDER BY concept, quarter_end, pref
    ),
    -- The comparisons: the row before (a quarter earlier if it is 70 to
    -- 110 days back), the fourth row before (a year earlier if 345 to 385
    -- days back); a gap in the series leaves the comparison NULL.
    series AS (
        SELECT q.concept, q.quarter_end, q.q_value, q.q_source, q.tradable_from,
               LAG(q.quarter_end, 1) OVER w AS e1, LAG(q.q_value, 1) OVER w AS v1,
               LAG(q.quarter_end, 4) OVER w AS e4, LAG(q.q_value, 4) OVER w AS v4,
               t.ttm_value, t.ttm_source, t.tradable_from AS ttm_tradable_from,
               LAG(t.quarter_end, 4) OVER w AS te4, LAG(t.ttm_value, 4) OVER w AS tv4
        FROM quarters q
        LEFT JOIN ttm t ON t.concept = q.concept AND t.quarter_end = q.quarter_end
        WINDOW w AS (PARTITION BY q.concept ORDER BY q.quarter_end)
    )
    SELECT s.concept, s.quarter_end, g.fiscal_quarter, s.tradable_from,
           s.q_value, s.q_source,
           CASE WHEN s.e1 BETWEEN s.quarter_end - 110 AND s.quarter_end - 70 THEN s.e1 END AS q_prior_end,
           CASE WHEN s.e1 BETWEEN s.quarter_end - 110 AND s.quarter_end - 70 THEN s.v1 END AS q_prior_value,
           CASE WHEN s.e1 BETWEEN s.quarter_end - 110 AND s.quarter_end - 70 AND s.v1 > 0
                THEN (s.q_value - s.v1) / s.v1 END AS qoq_growth,
           CASE WHEN s.e4 BETWEEN s.quarter_end - 385 AND s.quarter_end - 345 THEN s.e4 END AS q_yoy_end,
           CASE WHEN s.e4 BETWEEN s.quarter_end - 385 AND s.quarter_end - 345 THEN s.v4 END AS q_yoy_value,
           CASE WHEN s.e4 BETWEEN s.quarter_end - 385 AND s.quarter_end - 345 AND s.v4 > 0
                THEN (s.q_value - s.v4) / s.v4 END AS yoy_growth,
           s.ttm_value, s.ttm_source, s.ttm_tradable_from,
           CASE WHEN s.te4 BETWEEN s.quarter_end - 385 AND s.quarter_end - 345 THEN s.tv4 END AS ttm_prior_value,
           CASE WHEN s.te4 BETWEEN s.quarter_end - 385 AND s.quarter_end - 345 AND s.tv4 > 0 AND s.ttm_value IS NOT NULL
                THEN (s.ttm_value - s.tv4) / s.tv4 END AS ttm_growth
    FROM series s
    JOIN grid g ON g.value_date = s.quarter_end
    ORDER BY s.concept, s.quarter_end;
$$;

COMMENT ON FUNCTION sec_gold.as_of_quarterly(INTEGER, DATE, INTEGER) IS
    'Every fiscal quarter of every flow concept for a company as it was '
    'knowable on p_asof: the quarter''s value (filed, or the difference of '
    'two year-to-date figures), the trailing twelve months, and growth '
    'against the prior quarter, the same quarter a year earlier and the '
    'prior trailing year. Nothing stored; the knowledge date is required.';

-- ---------------------------------------------------------------
-- The newest quarter per concept.
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS sec_gold.as_of_trailing(INTEGER, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_trailing(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_prior_end      DATE,
    q_prior_value    NUMERIC,
    qoq_growth       NUMERIC,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_growth       NUMERIC,
    ttm_value        NUMERIC,
    ttm_source       TEXT,
    ttm_tradable_from DATE,
    ttm_prior_value  NUMERIC,
    ttm_growth       NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT DISTINCT ON (q.concept) q.*
    FROM sec_gold.as_of_quarterly(p_cik, p_asof, p_buffer_sessions) q
    ORDER BY q.concept, q.quarter_end DESC;
$$;

COMMENT ON FUNCTION sec_gold.as_of_trailing(INTEGER, DATE, INTEGER) IS
    'The newest fiscal quarter of every flow concept knowable on p_asof, '
    'with its trailing twelve months and the three growth rates; one row '
    'per concept. as_of_quarterly is the series behind it.';

DROP FUNCTION IF EXISTS sec_gold.as_of_trailing(TEXT, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_trailing(
    p_ticker           TEXT,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_prior_end      DATE,
    q_prior_value    NUMERIC,
    qoq_growth       NUMERIC,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_growth       NUMERIC,
    ttm_value        NUMERIC,
    ttm_source       TEXT,
    ttm_tradable_from DATE,
    ttm_prior_value  NUMERIC,
    ttm_growth       NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT *
    FROM sec_gold.as_of_trailing(sec_reference.cik_at_strict(p_ticker, p_asof), p_asof, p_buffer_sessions);
$$;

COMMENT ON FUNCTION sec_gold.as_of_trailing(TEXT, DATE, INTEGER) IS
    'Ticker form of as_of_trailing: the ticker is resolved as of the same '
    'date and the call raises if the crosswalk cannot resolve it.';

-- ---------------------------------------------------------------
-- As of today: the latest restated vintage of everything filed.
-- ---------------------------------------------------------------
DROP FUNCTION IF EXISTS sec_gold.quarterly(INTEGER);

CREATE FUNCTION sec_gold.quarterly(p_cik INTEGER)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_prior_end      DATE,
    q_prior_value    NUMERIC,
    qoq_growth       NUMERIC,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_growth       NUMERIC,
    ttm_value        NUMERIC,
    ttm_source       TEXT,
    ttm_tradable_from DATE,
    ttm_prior_value  NUMERIC,
    ttm_growth       NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM sec_gold.as_of_quarterly(p_cik, CURRENT_DATE, 0);
$$;

COMMENT ON FUNCTION sec_gold.quarterly(INTEGER) IS
    'as_of_quarterly as of today: every fiscal quarter of every flow '
    'concept at its latest restated vintage. Not for a backtest.';

DROP FUNCTION IF EXISTS sec_gold.trailing(INTEGER);

CREATE FUNCTION sec_gold.trailing(p_cik INTEGER)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_prior_end      DATE,
    q_prior_value    NUMERIC,
    qoq_growth       NUMERIC,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_growth       NUMERIC,
    ttm_value        NUMERIC,
    ttm_source       TEXT,
    ttm_tradable_from DATE,
    ttm_prior_value  NUMERIC,
    ttm_growth       NUMERIC
)
LANGUAGE sql STABLE AS $$
    SELECT * FROM sec_gold.as_of_trailing(p_cik, CURRENT_DATE, 0);
$$;

COMMENT ON FUNCTION sec_gold.trailing(INTEGER) IS
    'as_of_trailing as of today: the newest quarter and trailing twelve '
    'months of every flow concept at its latest restated vintage.';
