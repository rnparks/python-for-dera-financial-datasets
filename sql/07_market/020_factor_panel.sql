-- sql/07_market/020_factor_panel.sql
--
-- THE FACTOR PANEL: the factor sheet, stored, one knowledge date at a
-- time. sec_gold.factor_sheet_asof costs about 100 s per date for the
-- S&P 500, so a backtest that rebalances at 190 month ends cannot call
-- it on the fly; this table holds its output per (index, asof, cik),
-- built by `dera build-factor-panel`, which calls build_factor_panel
-- for each month end in turn.
--
-- POINT IN TIME, BY CONSTRUCTION. A row's `asof` is the knowledge date
-- the sheet was computed for; every value in the row is what
-- factor_sheet_asof returned for that date, which is what the gold
-- layer knew then. The row for 2015-06-30 built tonight is identical to
-- the row that would have been built on 2015-06-30, except where the
-- gold layer itself has since gained a filing it did not have (DERA
-- publishes quarterly), which the as-of functions bound by tradable_from
-- exactly as they do everywhere else. Rebuilding a date replaces its
-- rows; `built_at` says when.
--
-- DERIVED DATA, DROPPABLE. Nothing reads this but the backtest. The
-- S&P 500 at every month end 2010-2026 is about 100,000 rows; the 400
-- and 600 are built the same way from their replayed histories (2011
-- and 2018), and 'SP1500' is their union re-ranked, so the four together
-- are about 400,000 rows.

CREATE TABLE IF NOT EXISTS sec_market.factor_panel (
    index_name              TEXT    NOT NULL,
    asof                    DATE    NOT NULL,
    cik                     INTEGER NOT NULL,
    ticker                  TEXT,
    gics_sector             TEXT,
    annual_period           DATE,
    annual_tradable_from    DATE,
    quarter_end             DATE,
    quarter_tradable_from   DATE,
    gp_at                   NUMERIC, gp_at_pct NUMERIC, gp_at_sector_pct NUMERIC,
    ocf_at                  NUMERIC, ocf_at_pct NUMERIC, ocf_at_sector_pct NUMERIC,
    roa                     NUMERIC, roa_pct NUMERIC, roa_sector_pct NUMERIC,
    roe                     NUMERIC, roe_pct NUMERIC, roe_sector_pct NUMERIC,
    operating_margin        NUMERIC, operating_margin_pct NUMERIC, operating_margin_sector_pct NUMERIC,
    revenue_growth          NUMERIC, revenue_growth_pct NUMERIC, revenue_growth_sector_pct NUMERIC,
    roe_q                   NUMERIC, roe_q_pct NUMERIC, roe_q_sector_pct NUMERIC,
    roa_q                   NUMERIC, roa_q_pct NUMERIC, roa_q_sector_pct NUMERIC,
    sue                     NUMERIC, sue_pct NUMERIC, sue_sector_pct NUMERIC,
    n_factors               INTEGER NOT NULL DEFAULT 0,
    composite               NUMERIC,
    built_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (index_name, asof, cik),
    CHECK (annual_period IS NULL OR annual_period <= asof),
    CHECK (quarter_end IS NULL OR quarter_end <= asof),
    CHECK (annual_tradable_from IS NULL OR annual_tradable_from <= asof),
    CHECK (quarter_tradable_from IS NULL OR quarter_tradable_from <= asof)
);

COMMENT ON TABLE sec_market.factor_panel IS
    'sec_gold.factor_sheet_asof stored per (index, knowledge date, company) by dera build-factor-panel; '
    'the CHECKs refuse any row whose period or availability is after its own knowledge date.';

-- Build (or rebuild) one knowledge date. Returns the rows written.
CREATE OR REPLACE FUNCTION sec_market.build_factor_panel(p_index TEXT, p_asof DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    n INTEGER;
BEGIN
    -- The combined universe is a re-rank of the stored component panels,
    -- not a call of the sheet (see build_factor_panel_union below).
    IF p_index = 'SP1500' THEN
        RETURN sec_market.build_factor_panel_union('SP1500', ARRAY['SP500', 'SP400', 'SP600'], p_asof);
    END IF;
    DELETE FROM sec_market.factor_panel WHERE index_name = p_index AND asof = p_asof;
    INSERT INTO sec_market.factor_panel (
        index_name, asof, cik, ticker, gics_sector,
        annual_period, annual_tradable_from, quarter_end, quarter_tradable_from,
        gp_at, gp_at_pct, gp_at_sector_pct, ocf_at, ocf_at_pct, ocf_at_sector_pct,
        roa, roa_pct, roa_sector_pct, roe, roe_pct, roe_sector_pct,
        operating_margin, operating_margin_pct, operating_margin_sector_pct,
        revenue_growth, revenue_growth_pct, revenue_growth_sector_pct,
        roe_q, roe_q_pct, roe_q_sector_pct, roa_q, roa_q_pct, roa_q_sector_pct,
        sue, sue_pct, sue_sector_pct, n_factors, composite)
    SELECT p_index, p_asof, s.cik, s.ticker, s.gics_sector,
           s.annual_period, s.annual_tradable_from, s.quarter_end, s.quarter_tradable_from,
           s.gp_at, s.gp_at_pct, s.gp_at_sector_pct, s.ocf_at, s.ocf_at_pct, s.ocf_at_sector_pct,
           s.roa, s.roa_pct, s.roa_sector_pct, s.roe, s.roe_pct, s.roe_sector_pct,
           s.operating_margin, s.operating_margin_pct, s.operating_margin_sector_pct,
           s.revenue_growth, s.revenue_growth_pct, s.revenue_growth_sector_pct,
           s.roe_q, s.roe_q_pct, s.roe_q_sector_pct, s.roa_q, s.roa_q_pct, s.roa_q_sector_pct,
           s.sue, s.sue_pct, s.sue_sector_pct, s.n_factors, s.composite
    FROM sec_gold.factor_sheet_asof(p_index, p_asof) s;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

COMMENT ON FUNCTION sec_market.build_factor_panel(TEXT, DATE) IS
    'Replace the factor_panel rows of one index and knowledge date with sec_gold.factor_sheet_asof''s output; '
    'SP1500 is the union of the three component panels, re-ranked (build_factor_panel_union).';

-- THE COMBINED UNIVERSE. 'SP1500' is not an index the spine replays; it
-- is the union of the three panels on a date, re-ranked over all of
-- them. The stored values of each member are what the sheet computed
-- for its own index (a value does not depend on who else is in the
-- universe); only the percentiles and the composite do, so they are
-- recomputed here with the sheet's own rule (090): the signed value
-- (revenue_growth negated), PERCENT_RANK over the members that have
-- the factor, the same within the member's GICS sector, the composite
-- the mean of the index percentiles over four or more. One row per
-- company: a company in two component panels on one date (a seat moving
-- between indexes) takes the first component listed. Every component
-- must already hold the date, or nothing is written: a union of two
-- indexes labelled as three would be a different universe.
CREATE OR REPLACE FUNCTION sec_market.build_factor_panel_union(p_name TEXT, p_components TEXT[], p_asof DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    n INTEGER;
    missing TEXT;
BEGIN
    SELECT string_agg(c, ', ') INTO missing
    FROM unnest(p_components) AS c
    WHERE NOT EXISTS (SELECT 1 FROM sec_market.factor_panel fp WHERE fp.index_name = c AND fp.asof = p_asof);
    IF missing IS NOT NULL THEN
        RAISE EXCEPTION 'union % at %: component panel(s) % not built for that date', p_name, p_asof, missing;
    END IF;
    DELETE FROM sec_market.factor_panel WHERE index_name = p_name AND asof = p_asof;
    INSERT INTO sec_market.factor_panel (
        index_name, asof, cik, ticker, gics_sector,
        annual_period, annual_tradable_from, quarter_end, quarter_tradable_from,
        gp_at, gp_at_pct, gp_at_sector_pct, ocf_at, ocf_at_pct, ocf_at_sector_pct, roa, roa_pct, roa_sector_pct, roe, roe_pct, roe_sector_pct, operating_margin, operating_margin_pct, operating_margin_sector_pct, revenue_growth, revenue_growth_pct, revenue_growth_sector_pct, roe_q, roe_q_pct, roe_q_sector_pct, roa_q, roa_q_pct, roa_q_sector_pct, sue, sue_pct, sue_sector_pct, n_factors, composite)
    WITH members AS (
        SELECT DISTINCT ON (fp.cik) fp.*
        FROM sec_market.factor_panel fp
        WHERE fp.asof = p_asof AND fp.index_name = ANY (p_components)
        ORDER BY fp.cik, array_position(p_components, fp.index_name)
    ),
    long AS (
        SELECT m.cik, m.gics_sector, f.factor, f.signed_value
        FROM members m
        CROSS JOIN LATERAL (VALUES ('gp_at', m.gp_at), ('ocf_at', m.ocf_at), ('roa', m.roa), ('roe', m.roe), ('operating_margin', m.operating_margin), ('revenue_growth', -m.revenue_growth), ('roe_q', m.roe_q), ('roa_q', m.roa_q), ('sue', m.sue)) AS f(factor, signed_value)
        WHERE f.signed_value IS NOT NULL
    ),
    ranked AS (
        SELECT cik, factor,
               ROUND(PERCENT_RANK() OVER (PARTITION BY factor ORDER BY signed_value)::NUMERIC, 4) AS pct,
               ROUND(PERCENT_RANK() OVER (PARTITION BY factor, gics_sector ORDER BY signed_value)::NUMERIC, 4) AS sector_pct
        FROM long
    ),
    wide AS (
        SELECT cik,
               MAX(pct) FILTER (WHERE factor = 'gp_at') AS gp_at_pct, MAX(sector_pct) FILTER (WHERE factor = 'gp_at') AS gp_at_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'ocf_at') AS ocf_at_pct, MAX(sector_pct) FILTER (WHERE factor = 'ocf_at') AS ocf_at_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'roa') AS roa_pct, MAX(sector_pct) FILTER (WHERE factor = 'roa') AS roa_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'roe') AS roe_pct, MAX(sector_pct) FILTER (WHERE factor = 'roe') AS roe_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'operating_margin') AS operating_margin_pct, MAX(sector_pct) FILTER (WHERE factor = 'operating_margin') AS operating_margin_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'revenue_growth') AS revenue_growth_pct, MAX(sector_pct) FILTER (WHERE factor = 'revenue_growth') AS revenue_growth_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'roe_q') AS roe_q_pct, MAX(sector_pct) FILTER (WHERE factor = 'roe_q') AS roe_q_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'roa_q') AS roa_q_pct, MAX(sector_pct) FILTER (WHERE factor = 'roa_q') AS roa_q_sector_pct,
               MAX(pct) FILTER (WHERE factor = 'sue') AS sue_pct, MAX(sector_pct) FILTER (WHERE factor = 'sue') AS sue_sector_pct,
               COUNT(*)::INTEGER AS n_factors,
               ROUND(AVG(pct), 4) AS composite_raw
        FROM ranked
        GROUP BY cik
    )
    SELECT p_name, p_asof, m.cik, m.ticker, m.gics_sector,
           m.annual_period, m.annual_tradable_from, m.quarter_end, m.quarter_tradable_from,
           m.gp_at, w.gp_at_pct, w.gp_at_sector_pct, m.ocf_at, w.ocf_at_pct, w.ocf_at_sector_pct, m.roa, w.roa_pct, w.roa_sector_pct, m.roe, w.roe_pct, w.roe_sector_pct, m.operating_margin, w.operating_margin_pct, w.operating_margin_sector_pct, m.revenue_growth, w.revenue_growth_pct, w.revenue_growth_sector_pct, m.roe_q, w.roe_q_pct, w.roe_q_sector_pct, m.roa_q, w.roa_q_pct, w.roa_q_sector_pct, m.sue, w.sue_pct, w.sue_sector_pct,
           COALESCE(w.n_factors, 0), CASE WHEN w.n_factors >= 4 THEN w.composite_raw END
    FROM members m
    LEFT JOIN wide w USING (cik);
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END;
$$;

COMMENT ON FUNCTION sec_market.build_factor_panel_union(TEXT, TEXT[], DATE) IS
    'Write one knowledge date of a combined universe: the component panels'' rows, one per company, '
    'with the percentiles and composite recomputed over the union by the factor sheet''s rule.';

