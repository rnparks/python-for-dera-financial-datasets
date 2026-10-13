-- sql/03_gold/068_surprise.sql
--
-- STANDARDIZED UNEXPECTED EARNINGS, computed on demand. Foster, Olsen
-- and Shevlin (1984): the change in a quarter's earnings against the
-- same quarter a year earlier, divided by the historical standard
-- deviation of those changes.
--
--     SUE_t = (E_t - E_{t-4}) / sigma_t
--
-- where sigma_t is the sample standard deviation of the eight prior
-- seasonal changes, E_{t-1} - E_{t-5} through E_{t-8} - E_{t-12}. The
-- eight-quarter window is the one JKP's niq_su uses (Jensen, Kelly and
-- Pedersen 2023); JKP also subtract the mean of those changes (the
-- Jegadeesh and Livnat 2006 drift), which this does not: the request
-- was the original form, and the mean is one more window away if ever
-- wanted.
--
-- NOTHING OVER SOMETHING PLAUSIBLE. A quarter whose eight prior changes
-- are not all there, or do not come from eight consecutive quarters
-- (the eighth-previous quarter-end 700-760 days back, which tolerates
-- 52/53-week years and DERA's month-end rounding), gets NULL, never a
-- figure from a shorter or gappy window; `prior_changes` says how many
-- were there. A sigma of zero is NULL too.
--
-- EVERY FIGURE IS A VINTAGE KNOWABLE ON p_asof. The quarters come from
-- as_of_quarterly (067): the filed three-month figure or the difference
-- of two year-to-date figures, the same-quarter-prior-year value matched
-- by date window, each at the vintage actionable on the knowledge date.
-- So E_{t-4} is the comparative as the market knew it then, restated
-- or not, and the newest quarter is the one whose filing had landed.
--
-- A FUNCTION, NOT A TABLE. Nothing is stored; a company takes the cost
-- of one as_of_quarterly call (about 40-60 ms warm), an S&P 500
-- cross-section about 25 s.
--
-- as_of_surprise(cik, asof[, concept[, buffer]])   every quarter, one company
-- surprise_asof(index, asof[, concept[, max_age[, buffer]]])
--                                                   the newest quarter of every
--                                                   constituent, ranked

DROP FUNCTION IF EXISTS sec_gold.surprise_asof(TEXT, DATE, TEXT, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS sec_gold.as_of_surprise(INTEGER, DATE, TEXT, INTEGER);

CREATE FUNCTION sec_gold.as_of_surprise(
    p_cik              INTEGER,
    p_asof             DATE,
    p_concept          TEXT    DEFAULT 'net_income',
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    q_value          NUMERIC,
    q_source         TEXT,
    q_yoy_end        DATE,
    q_yoy_value      NUMERIC,
    yoy_change       NUMERIC,
    prior_changes    INTEGER,
    sigma            NUMERIC,
    sue              NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH q AS (
    SELECT q.concept, q.quarter_end, q.fiscal_quarter, q.tradable_from,
           q.q_value, q.q_source, q.q_yoy_end, q.q_yoy_value,
           q.q_value - q.q_yoy_value AS yoy_change
    FROM sec_gold.as_of_quarterly(p_cik, p_asof, p_buffer_sessions) q
    WHERE q.concept = p_concept
      AND q.q_value IS NOT NULL
),
w AS (
    SELECT q.*,
           COUNT(q.yoy_change)       OVER (ORDER BY q.quarter_end
                                           ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS n_prior,
           STDDEV_SAMP(q.yoy_change) OVER (ORDER BY q.quarter_end
                                           ROWS BETWEEN 8 PRECEDING AND 1 PRECEDING) AS sigma_raw,
           q.quarter_end - LAG(q.quarter_end, 8) OVER (ORDER BY q.quarter_end) AS span_days
    FROM q
)
SELECT w.concept, w.quarter_end, w.fiscal_quarter, w.tradable_from,
       w.q_value, w.q_source, w.q_yoy_end, w.q_yoy_value, w.yoy_change,
       w.n_prior::INTEGER AS prior_changes,
       CASE WHEN w.n_prior = 8 AND w.span_days BETWEEN 700 AND 760
            THEN w.sigma_raw END AS sigma,
       CASE WHEN w.n_prior = 8 AND w.span_days BETWEEN 700 AND 760
             AND w.sigma_raw > 0 AND w.yoy_change IS NOT NULL
            THEN w.yoy_change / w.sigma_raw END AS sue
FROM w
ORDER BY w.quarter_end;
$$;

COMMENT ON FUNCTION sec_gold.as_of_surprise(INTEGER, DATE, TEXT, INTEGER) IS
    'Standardized unexpected earnings (Foster, Olsen and Shevlin 1984) for '
    'every fiscal quarter of one flow concept (default net_income) of one '
    'company as knowable on p_asof: the year-over-year change in the '
    'quarter divided by the sample standard deviation of the eight prior '
    'changes, which must come from eight consecutive quarters; else NULL. '
    'Computed on demand from as_of_quarterly; nothing is stored.';

CREATE FUNCTION sec_gold.surprise_asof(
    p_index            TEXT,
    p_asof             DATE,
    p_concept          TEXT    DEFAULT 'net_income',
    p_max_age_days     INTEGER DEFAULT 200,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    cik              INTEGER,
    ticker           TEXT,
    index_name       TEXT,
    gics_sector      TEXT,
    concept          TEXT,
    quarter_end      DATE,
    fiscal_quarter   INTEGER,
    tradable_from    DATE,
    days_stale       INTEGER,
    q_value          NUMERIC,
    q_yoy_value      NUMERIC,
    yoy_change       NUMERIC,
    prior_changes    INTEGER,
    sigma            NUMERIC,
    sue              NUMERIC,
    sue_rank         BIGINT,
    sue_percentile   NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH members AS (
    -- Constituents ON the knowledge date, ticker as of it (as 085).
    SELECT m.cik,
           COALESCE(sec_reference.ticker_at(m.cik, p_asof), m.ticker) AS ticker,
           p_index AS index_name, m.gics_sector
    FROM sec_reference.index_members(p_index, p_asof) m
),
-- The newest quarter knowable on the date per member. A quarter older
-- than p_max_age_days (default 200: a quarter, the 10-K deadline and
-- room for a late filer) is left out rather than ranked against fresher
-- peers, as in peer_stats_asof.
newest AS (
    SELECT DISTINCT ON (mb.cik)
           mb.cik, mb.ticker, mb.index_name, mb.gics_sector,
           s.concept, s.quarter_end, s.fiscal_quarter, s.tradable_from,
           (p_asof - s.quarter_end)::INTEGER AS days_stale,
           s.q_value, s.q_yoy_value, s.yoy_change, s.prior_changes, s.sigma, s.sue
    FROM members mb
    CROSS JOIN LATERAL sec_gold.as_of_surprise(mb.cik, p_asof, p_concept, p_buffer_sessions) s
    WHERE p_asof - s.quarter_end <= p_max_age_days
    ORDER BY mb.cik, s.quarter_end DESC
),
-- Rank and percentile over the members with a SUE; the others keep
-- their row, with prior_changes saying why there is none.
scored AS (
    SELECT n.cik,
           RANK() OVER (ORDER BY n.sue DESC) AS sue_rank,
           ROUND(PERCENT_RANK() OVER (ORDER BY n.sue)::NUMERIC, 4) AS sue_percentile
    FROM newest n
    WHERE n.sue IS NOT NULL
)
SELECT n.cik, n.ticker, n.index_name, n.gics_sector,
       n.concept, n.quarter_end, n.fiscal_quarter, n.tradable_from, n.days_stale,
       n.q_value, n.q_yoy_value, n.yoy_change, n.prior_changes, n.sigma, n.sue,
       s.sue_rank, s.sue_percentile
FROM newest n
LEFT JOIN scored s ON s.cik = n.cik
ORDER BY s.sue_rank NULLS LAST, n.ticker;
$$;

COMMENT ON FUNCTION sec_gold.surprise_asof(TEXT, DATE, TEXT, INTEGER, INTEGER) IS
    'Standardized unexpected earnings of every constituent of an index as '
    'knowable on p_asof: each member''s newest quarter (not older than '
    'p_max_age_days) with its SUE from as_of_surprise, ranked and '
    'percentiled over the members that have one; members without one '
    'keep their row with prior_changes saying why. Computed on demand; '
    'nothing is stored.';
