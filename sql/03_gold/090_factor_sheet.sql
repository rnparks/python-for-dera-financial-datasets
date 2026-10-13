-- sql/03_gold/090_factor_sheet.sql
--
-- THE FACTOR SHEET: one row per index constituent, every accounting
-- factor the gold layer computes, each as a value and as two
-- percentiles, all as knowable on one date. The stock-picking entry
-- point; a composite for a first sort.
--
-- Nine factors, each with the sign JKP attach to it (Jensen, Kelly and
-- Pedersen 2023) so that a HIGHER percentile always means the HIGHER
-- expected return the literature found:
--
--     gp_at            gross_profit_to_assets   +   Novy-Marx (2013)
--     ocf_at           ocf_to_assets            +   Bouchaud et al. (2019)
--     roa              roa                      +   (ni_at)
--     roe              roe                      +   Haugen and Baker (1996)
--     operating_margin operating_margin         +   Soliman (2008), ebit_sale
--     revenue_growth   revenue_growth           -   Lakonishok, Shleifer and
--                                                   Vishny (1994), sale_gr1
--     roe_q            as_of_profitability      +   Hou, Xue and Zhang (2015)
--     roa_q            as_of_profitability      +   Balakrishnan et al. (2010)
--     sue              as_of_surprise           +   Foster, Olsen and Shevlin
--
-- *_pct is the percentile over the index members that have the factor
-- on the date (0 = worst, 1 = best expected return); *_sector_pct the
-- same within the member's GICS sector, so a sector-neutral sort is one
-- ORDER BY away. composite is the plain mean of the index percentiles
-- a member has, n_factors how many; a member with fewer than four is
-- left unscored. Equal weights are a starting point, not a finding.
--
-- EVERY INPUT IS A VINTAGE KNOWABLE ON p_asof. The annual factors come
-- from peer_stats_asof (085): the newest fiscal year whose figures had
-- been filed by the date, not older than p_max_age_days. The quarterly
-- ones from profitability_asof (069) and surprise_asof (068): the
-- newest quarter filed by the date, not older than p_quarter_max_age.
-- Membership and ticker are as of the date. Nothing here can see past
-- the knowledge date, because nothing it reads can.
--
-- A FUNCTION, NOT A TABLE. One call runs the three cross-sections it
-- composes: about 70 s for the S&P 500; nothing is stored.
--
-- factor_sheet_asof(index, asof[, max_age[, quarter_max_age[, buffer]]])

DROP FUNCTION IF EXISTS sec_gold.factor_sheet_asof(TEXT, DATE, INTEGER, INTEGER, INTEGER);

CREATE FUNCTION sec_gold.factor_sheet_asof(
    p_index              TEXT,
    p_asof               DATE,
    p_max_age_days       INTEGER DEFAULT 550,
    p_quarter_max_age    INTEGER DEFAULT 200,
    p_buffer_sessions    INTEGER DEFAULT 0
)
RETURNS TABLE (
    cik                     INTEGER,
    ticker                  TEXT,
    index_name              TEXT,
    gics_sector             TEXT,
    annual_period           DATE,
    annual_tradable_from    DATE,
    quarter_end             DATE,
    quarter_tradable_from   DATE,
    gp_at                   NUMERIC,
    gp_at_pct               NUMERIC,
    gp_at_sector_pct        NUMERIC,
    ocf_at                  NUMERIC,
    ocf_at_pct              NUMERIC,
    ocf_at_sector_pct       NUMERIC,
    roa                     NUMERIC,
    roa_pct                 NUMERIC,
    roa_sector_pct          NUMERIC,
    roe                     NUMERIC,
    roe_pct                 NUMERIC,
    roe_sector_pct          NUMERIC,
    operating_margin        NUMERIC,
    operating_margin_pct    NUMERIC,
    operating_margin_sector_pct NUMERIC,
    revenue_growth          NUMERIC,
    revenue_growth_pct      NUMERIC,
    revenue_growth_sector_pct NUMERIC,
    roe_q                   NUMERIC,
    roe_q_pct               NUMERIC,
    roe_q_sector_pct        NUMERIC,
    roa_q                   NUMERIC,
    roa_q_pct               NUMERIC,
    roa_q_sector_pct        NUMERIC,
    sue                     NUMERIC,
    sue_pct                 NUMERIC,
    sue_sector_pct          NUMERIC,
    n_factors               INTEGER,
    composite               NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH members AS (
    -- Constituents ON the knowledge date, ticker as of it (as 085). ONE
    -- ROW PER COMPANY: the sheet is per registrant, and a company can
    -- hold two seats on a date when the crosswalk still assigns a seat's
    -- ticker to its previous holder (IR was Ingersoll-Rand plc until
    -- 2020-03-02 and Ingersoll Rand Inc from 2020-03-03; the crosswalk
    -- moves it at its next capture, 2020-06-28, so for three month ends
    -- the S&P 500's IR and TT seats both resolve to Trane Technologies,
    -- 1466258). Counted twice the company would rank twice and the panel's
    -- key would refuse the date; the seat whose ticker the spine assigns
    -- the company on the date wins, then the first ticker. Check 71 pins
    -- the count of such dates so growth is seen, not absorbed.
    SELECT DISTINCT ON (m.cik)
           m.cik,
           COALESCE(sec_reference.ticker_at(m.cik, p_asof), m.ticker) AS ticker,
           p_index AS index_name, m.gics_sector
    FROM sec_reference.index_members(p_index, p_asof) m
    ORDER BY m.cik, (m.ticker = sec_reference.ticker_at(m.cik, p_asof)) DESC, m.ticker
),
-- The annual factors: one row per member and concept from the
-- knowledge-date cross-section (sector level carries the value; the
-- sub-industry rows carry the same value).
annual AS (
    SELECT ps.cik, ps.concept, ps.value, ps.value_date, ps.tradable_from
    FROM sec_gold.peer_stats_asof(p_index, p_asof, p_max_age_days, p_buffer_sessions) ps
    WHERE ps.peer_level = 'sector'
      AND ps.concept IN ('gross_profit_to_assets', 'ocf_to_assets', 'roa', 'roe',
                         'operating_margin', 'revenue_growth')
),
-- The quarterly cross-section, run once (materialized: it is read
-- three times below and costs about 40 s for the S&P 500).
quarterly AS MATERIALIZED (
    SELECT pr.cik, pr.quarter_end, pr.tradable_from, pr.roe_q, pr.roa_q
    FROM sec_gold.profitability_asof(p_index, p_asof, p_quarter_max_age, p_buffer_sessions) pr
),
-- Every factor as a signed value in one long table: the sign makes a
-- higher value the better expected return, so one PERCENT_RANK serves
-- all nine.
long AS (
    SELECT a.cik, a.concept AS factor, a.value,
           CASE WHEN a.concept = 'revenue_growth' THEN -a.value ELSE a.value END AS signed_value
    FROM annual a
    UNION ALL
    SELECT q.cik, 'roe_q', q.roe_q, q.roe_q FROM quarterly q WHERE q.roe_q IS NOT NULL
    UNION ALL
    SELECT q.cik, 'roa_q', q.roa_q, q.roa_q FROM quarterly q WHERE q.roa_q IS NOT NULL
    UNION ALL
    SELECT su.cik, 'sue', su.sue, su.sue
    FROM sec_gold.surprise_asof(p_index, p_asof, 'net_income', p_quarter_max_age, p_buffer_sessions) su
    WHERE su.sue IS NOT NULL
),
ranked AS (
    SELECT l.cik, l.factor, l.value,
           ROUND(PERCENT_RANK() OVER (PARTITION BY l.factor ORDER BY l.signed_value)::NUMERIC, 4) AS pct,
           ROUND(PERCENT_RANK() OVER (PARTITION BY l.factor, mb.gics_sector ORDER BY l.signed_value)::NUMERIC, 4) AS sector_pct
    FROM long l
    JOIN members mb ON mb.cik = l.cik
),
-- The newest annual period and quarter per member, for the dates.
annual_dates AS (
    SELECT a.cik, MAX(a.value_date) AS annual_period, MAX(a.tradable_from) AS annual_tradable_from
    FROM annual a GROUP BY a.cik
),
quarter_dates AS (
    SELECT q.cik, q.quarter_end, q.tradable_from AS quarter_tradable_from FROM quarterly q
),
wide AS (
    SELECT r.cik,
           MAX(value) FILTER (WHERE factor = 'gross_profit_to_assets') AS gp_at,
           MAX(pct) FILTER (WHERE factor = 'gross_profit_to_assets') AS gp_at_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'gross_profit_to_assets') AS gp_at_sector_pct,
           MAX(value) FILTER (WHERE factor = 'ocf_to_assets') AS ocf_at,
           MAX(pct) FILTER (WHERE factor = 'ocf_to_assets') AS ocf_at_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'ocf_to_assets') AS ocf_at_sector_pct,
           MAX(value) FILTER (WHERE factor = 'roa') AS roa,
           MAX(pct) FILTER (WHERE factor = 'roa') AS roa_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'roa') AS roa_sector_pct,
           MAX(value) FILTER (WHERE factor = 'roe') AS roe,
           MAX(pct) FILTER (WHERE factor = 'roe') AS roe_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'roe') AS roe_sector_pct,
           MAX(value) FILTER (WHERE factor = 'operating_margin') AS operating_margin,
           MAX(pct) FILTER (WHERE factor = 'operating_margin') AS operating_margin_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'operating_margin') AS operating_margin_sector_pct,
           MAX(value) FILTER (WHERE factor = 'revenue_growth') AS revenue_growth,
           MAX(pct) FILTER (WHERE factor = 'revenue_growth') AS revenue_growth_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'revenue_growth') AS revenue_growth_sector_pct,
           MAX(value) FILTER (WHERE factor = 'roe_q') AS roe_q,
           MAX(pct) FILTER (WHERE factor = 'roe_q') AS roe_q_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'roe_q') AS roe_q_sector_pct,
           MAX(value) FILTER (WHERE factor = 'roa_q') AS roa_q,
           MAX(pct) FILTER (WHERE factor = 'roa_q') AS roa_q_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'roa_q') AS roa_q_sector_pct,
           MAX(value) FILTER (WHERE factor = 'sue') AS sue,
           MAX(pct) FILTER (WHERE factor = 'sue') AS sue_pct,
           MAX(sector_pct) FILTER (WHERE factor = 'sue') AS sue_sector_pct,
           COUNT(*)::INTEGER AS n_factors,
           ROUND(AVG(pct), 4) AS composite_raw
    FROM ranked r
    GROUP BY r.cik
)
SELECT mb.cik, mb.ticker, mb.index_name, mb.gics_sector,
       ad.annual_period, ad.annual_tradable_from, qd.quarter_end, qd.quarter_tradable_from,
       w.gp_at, w.gp_at_pct, w.gp_at_sector_pct,
       w.ocf_at, w.ocf_at_pct, w.ocf_at_sector_pct,
       w.roa, w.roa_pct, w.roa_sector_pct,
       w.roe, w.roe_pct, w.roe_sector_pct,
       w.operating_margin, w.operating_margin_pct, w.operating_margin_sector_pct,
       w.revenue_growth, w.revenue_growth_pct, w.revenue_growth_sector_pct,
       w.roe_q, w.roe_q_pct, w.roe_q_sector_pct,
       w.roa_q, w.roa_q_pct, w.roa_q_sector_pct,
       w.sue, w.sue_pct, w.sue_sector_pct,
       COALESCE(w.n_factors, 0) AS n_factors,
       CASE WHEN w.n_factors >= 4 THEN w.composite_raw END AS composite
FROM members mb
LEFT JOIN wide w ON w.cik = mb.cik
LEFT JOIN annual_dates ad ON ad.cik = mb.cik
LEFT JOIN quarter_dates qd ON qd.cik = mb.cik
ORDER BY composite DESC NULLS LAST, mb.ticker;
$$;

COMMENT ON FUNCTION sec_gold.factor_sheet_asof(TEXT, DATE, INTEGER, INTEGER, INTEGER) IS
    'One row per constituent of an index as knowable on p_asof with nine '
    'accounting factors (gross profit and operating cash flow to assets, '
    'ROA, ROE, operating margin, revenue growth, quarterly ROE and ROA, '
    'SUE), each as a value, an index percentile and a GICS-sector '
    'percentile signed so that higher means the higher expected return in '
    'the literature, and an equal-weight composite over four or more. '
    'Composed from peer_stats_asof, profitability_asof and surprise_asof; '
    'nothing is stored.';
