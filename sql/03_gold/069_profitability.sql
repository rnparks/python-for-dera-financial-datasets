-- sql/03_gold/069_profitability.sql
--
-- QUARTERLY RETURN ON EQUITY AND ON ASSETS, computed on demand. JKP's
-- niq_be and niq_at (Hou, Xue and Zhang 2015; Balakrishnan, Bartov and
-- Faurel 2010): the quarter's net income over the book equity, or the
-- total assets, at the END OF THE PRIOR QUARTER.
--
--     roe_q = NI_q / BE_{q-1}        roa_q = NI_q / AT_{q-1}
--
-- The prior balance, not the same quarter's: JKP scale by BE_{t-3} (the
-- balance three months before the quarter end), so the capital the
-- quarter was earned ON, before the quarter's own earnings and buybacks
-- moved it. The annual roe and roa in concept_ratio use the fiscal
-- year-end balance; this is the quarterly, lagged form.
--
-- THE PRIOR QUARTER END IS THE MONTH END THREE MONTHS BACK. DERA rounds
-- every period end to a month end, so the balance for a quarter ending
-- 2024-06-30 is dated 2024-03-31, for a 52/53-week quarter ending
-- 2024-02-03 (rounded to 2024-01-31) it is 2023-10-31. For a first
-- fiscal quarter that balance is the fiscal year-end one, from the 10-K.
--
-- NOTHING OVER SOMETHING PLAUSIBLE. A balance that did not resolve at
-- that date as of the knowledge date, or is not positive, gives NULL;
-- never the same quarter's balance, never an older one.
--
-- EVERY FIGURE IS A VINTAGE KNOWABLE ON p_asof. The quarter comes from
-- as_of_quarterly (067), the balances from as_of_canonical_at (065),
-- all bounded by the same knowledge date, and tradable_from is the
-- later of the income's and the balances' availability.
--
-- A FUNCTION, NOT A TABLE. Nothing is stored. One company, every
-- quarter: one as_of_quarterly call plus two balance lookups per
-- quarter, about 0.5 s warm for 64 quarters; p_since keeps it to the
-- quarters that matter. The index form asks only for quarters inside
-- p_max_age_days, so an S&P 500 cross-section is about 45 s.
--
-- as_of_profitability(cik, asof[, since[, buffer]])   every quarter, one company
-- profitability_asof(index, asof[, max_age[, buffer]])
--                                                     the newest quarter of every
--                                                     constituent, ranked

DROP FUNCTION IF EXISTS sec_gold.profitability_asof(TEXT, DATE, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS sec_gold.as_of_profitability(INTEGER, DATE, DATE, INTEGER);

CREATE FUNCTION sec_gold.as_of_profitability(
    p_cik              INTEGER,
    p_asof             DATE,
    p_since            DATE    DEFAULT NULL,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    quarter_end        DATE,
    fiscal_quarter     INTEGER,
    tradable_from      DATE,
    net_income         NUMERIC,
    net_income_source  TEXT,
    balance_end        DATE,
    total_equity       NUMERIC,
    total_assets       NUMERIC,
    roe_q              NUMERIC,
    roa_q              NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH q AS (
    SELECT q.quarter_end, q.fiscal_quarter, q.tradable_from,
           q.q_value AS net_income, q.q_source AS net_income_source,
           -- The month end three months before the quarter end.
           (date_trunc('month', q.quarter_end - INTERVAL '2 months') - INTERVAL '1 day')::DATE AS balance_end
    FROM sec_gold.as_of_quarterly(p_cik, p_asof, p_buffer_sessions) q
    WHERE q.concept = 'net_income'
      AND q.q_value IS NOT NULL
      AND (p_since IS NULL OR q.quarter_end >= p_since)
)
SELECT q.quarter_end, q.fiscal_quarter,
       GREATEST(q.tradable_from, e.tradable_from, a.tradable_from) AS tradable_from,
       q.net_income, q.net_income_source, q.balance_end,
       e.value AS total_equity,
       a.value AS total_assets,
       CASE WHEN e.value > 0 THEN q.net_income / e.value END AS roe_q,
       CASE WHEN a.value > 0 THEN q.net_income / a.value END AS roa_q
FROM q
CROSS JOIN LATERAL sec_gold.as_of_canonical_at(p_cik, 'total_equity', q.balance_end, p_asof, p_buffer_sessions) e
CROSS JOIN LATERAL sec_gold.as_of_canonical_at(p_cik, 'total_assets', q.balance_end, p_asof, p_buffer_sessions) a
ORDER BY q.quarter_end;
$$;

COMMENT ON FUNCTION sec_gold.as_of_profitability(INTEGER, DATE, DATE, INTEGER) IS
    'Quarterly return on equity and on assets (JKP niq_be, niq_at) for '
    'every fiscal quarter of one company as knowable on p_asof: the '
    'quarter''s net income over the book equity, and over the total '
    'assets, at the end of the prior quarter (the month end three months '
    'back); NULL when that balance did not resolve or is not positive. '
    'p_since keeps only quarters ending on or after it. Computed on '
    'demand from as_of_quarterly and as_of_canonical_at; nothing is stored.';

CREATE FUNCTION sec_gold.profitability_asof(
    p_index            TEXT,
    p_asof             DATE,
    p_max_age_days     INTEGER DEFAULT 200,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    cik                INTEGER,
    ticker             TEXT,
    index_name         TEXT,
    gics_sector        TEXT,
    quarter_end        DATE,
    fiscal_quarter     INTEGER,
    tradable_from      DATE,
    days_stale         INTEGER,
    net_income         NUMERIC,
    balance_end        DATE,
    total_equity       NUMERIC,
    total_assets       NUMERIC,
    roe_q              NUMERIC,
    roa_q              NUMERIC,
    roe_rank           BIGINT,
    roe_percentile     NUMERIC,
    roa_rank           BIGINT,
    roa_percentile     NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH members AS (
    -- Constituents ON the knowledge date, ticker as of it (as 085).
    SELECT m.cik,
           COALESCE(sec_reference.ticker_at(m.cik, p_asof), m.ticker) AS ticker,
           p_index AS index_name, m.gics_sector
    FROM sec_reference.index_members(p_index, p_asof) m
),
-- The newest quarter knowable on the date per member, among quarters
-- ending within p_max_age_days (default 200: a quarter, the 10-K
-- deadline and room for a late filer), as in surprise_asof.
newest AS (
    SELECT DISTINCT ON (mb.cik)
           mb.cik, mb.ticker, mb.index_name, mb.gics_sector,
           p.quarter_end, p.fiscal_quarter, p.tradable_from,
           (p_asof - p.quarter_end)::INTEGER AS days_stale,
           p.net_income, p.balance_end, p.total_equity, p.total_assets, p.roe_q, p.roa_q
    FROM members mb
    CROSS JOIN LATERAL sec_gold.as_of_profitability(
        mb.cik, p_asof, p_asof - p_max_age_days, p_buffer_sessions) p
    ORDER BY mb.cik, p.quarter_end DESC
),
-- Rank and percentile over the members with a value, each measure on
-- its own base; the others keep their row, with the missing or
-- non-positive balance visible.
roe AS (
    SELECT n.cik,
           RANK() OVER (ORDER BY n.roe_q DESC) AS roe_rank,
           ROUND(PERCENT_RANK() OVER (ORDER BY n.roe_q)::NUMERIC, 4) AS roe_percentile
    FROM newest n
    WHERE n.roe_q IS NOT NULL
),
roa AS (
    SELECT n.cik,
           RANK() OVER (ORDER BY n.roa_q DESC) AS roa_rank,
           ROUND(PERCENT_RANK() OVER (ORDER BY n.roa_q)::NUMERIC, 4) AS roa_percentile
    FROM newest n
    WHERE n.roa_q IS NOT NULL
)
SELECT n.cik, n.ticker, n.index_name, n.gics_sector,
       n.quarter_end, n.fiscal_quarter, n.tradable_from, n.days_stale,
       n.net_income, n.balance_end, n.total_equity, n.total_assets, n.roe_q, n.roa_q,
       e.roe_rank, e.roe_percentile, a.roa_rank, a.roa_percentile
FROM newest n
LEFT JOIN roe e ON e.cik = n.cik
LEFT JOIN roa a ON a.cik = n.cik
ORDER BY e.roe_rank NULLS LAST, n.ticker;
$$;

COMMENT ON FUNCTION sec_gold.profitability_asof(TEXT, DATE, INTEGER, INTEGER) IS
    'Quarterly return on equity and on assets of every constituent of an '
    'index as knowable on p_asof: each member''s newest quarter (not older '
    'than p_max_age_days) from as_of_profitability, ranked (1 = highest) '
    'and percentiled (1 = highest) over the members that have a value; a '
    'member without one keeps its row. Computed on demand; nothing is stored.';
