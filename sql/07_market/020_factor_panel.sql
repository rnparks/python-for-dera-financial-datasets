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
-- S&P 500 at every month end 2010-2025 is about 95,000 rows.

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
    'Replace the factor_panel rows of one index and knowledge date with sec_gold.factor_sheet_asof''s output.';
