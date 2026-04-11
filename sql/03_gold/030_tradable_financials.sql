-- Gold layer: S&P 1500 tradable universe crossed with silver facts.
--
-- Two sibling matviews: "latest" for fundamental analysis (restated
-- figures) and "pit" for backtesting (as-first-reported). Both read
-- through sec_silver.financials() so the segments/coreg filter is not
-- duplicated here.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials_pit    CASCADE;

CREATE MATERIALIZED VIEW sec_gold.tradable_financials AS
SELECT
    u.ticker,
    u.name        AS company_name,
    u.index_name,
    f.cik,
    f.tag,
    f.tlabel      AS metric,
    f.value_date,
    f.filed_date,
    f.qtrs,
    f.uom,
    f.value,
    f.adsh
FROM sec_silver.universe_sp1500 u
JOIN sec_silver.ticker_map      m USING (ticker)
JOIN sec_silver.financials('latest') f ON f.cik = m.cik;

CREATE INDEX idx_tradable_ticker ON sec_gold.tradable_financials (ticker);
CREATE INDEX idx_tradable_date   ON sec_gold.tradable_financials (value_date);
CREATE INDEX idx_tradable_tag    ON sec_gold.tradable_financials (tag);
CREATE INDEX idx_tradable_cik    ON sec_gold.tradable_financials (cik);

CREATE MATERIALIZED VIEW sec_gold.tradable_financials_pit AS
SELECT
    u.ticker,
    u.name        AS company_name,
    u.index_name,
    f.cik,
    f.tag,
    f.tlabel      AS metric,
    f.value_date,
    f.filed_date,
    f.qtrs,
    f.uom,
    f.value,
    f.adsh
FROM sec_silver.universe_sp1500 u
JOIN sec_silver.ticker_map      m USING (ticker)
JOIN sec_silver.financials('pit') f ON f.cik = m.cik;

CREATE INDEX idx_tradable_pit_ticker ON sec_gold.tradable_financials_pit (ticker);
CREATE INDEX idx_tradable_pit_date   ON sec_gold.tradable_financials_pit (value_date);
CREATE INDEX idx_tradable_pit_tag    ON sec_gold.tradable_financials_pit (tag);
CREATE INDEX idx_tradable_pit_cik    ON sec_gold.tradable_financials_pit (cik);
