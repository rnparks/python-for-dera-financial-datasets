-- Gold layer: S&P 1500 tradable universe crossed with silver facts.
--
-- Two sibling matviews: "latest" for fundamental analysis (restated
-- figures) and "pit" for backtesting (as-first-reported).
--
-- These query sec_silver.num_silver directly rather than routing
-- through sec_silver.financials() — the SQL function does not inline
-- cleanly inside a CREATE MATERIALIZED VIEW with joins (the
-- mode-based OR predicate blocks the rank_{pit,latest} index scan),
-- which turned a ~30s build into a >12m build during verification.
-- The filter logic is identical to the function body; the function
-- remains as the convenience entry point for ad-hoc silver queries.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials_pit    CASCADE;

CREATE MATERIALIZED VIEW sec_gold.tradable_financials AS
SELECT
    u.ticker,
    u.name        AS company_name,
    u.index_name,
    n.cik,
    n.tag,
    n.tlabel      AS metric,
    n.value_date,
    n.filed_date,
    n.qtrs,
    n.uom,
    n.value,
    n.adsh
FROM sec_silver.universe_sp1500 u
JOIN sec_silver.ticker_map      m USING (ticker)
JOIN sec_silver.num_silver      n ON n.cik = m.cik
WHERE n.rank_latest = 1
  AND n.segments IS NULL
  AND n.coreg    IS NULL;

CREATE INDEX idx_tradable_ticker ON sec_gold.tradable_financials (ticker);
CREATE INDEX idx_tradable_date   ON sec_gold.tradable_financials (value_date);
CREATE INDEX idx_tradable_tag    ON sec_gold.tradable_financials (tag);
CREATE INDEX idx_tradable_cik    ON sec_gold.tradable_financials (cik);

CREATE MATERIALIZED VIEW sec_gold.tradable_financials_pit AS
SELECT
    u.ticker,
    u.name        AS company_name,
    u.index_name,
    n.cik,
    n.tag,
    n.tlabel      AS metric,
    n.value_date,
    n.filed_date,
    n.qtrs,
    n.uom,
    n.value,
    n.adsh
FROM sec_silver.universe_sp1500 u
JOIN sec_silver.ticker_map      m USING (ticker)
JOIN sec_silver.num_silver      n ON n.cik = m.cik
WHERE n.rank_pit = 1
  AND n.segments IS NULL
  AND n.coreg    IS NULL;

CREATE INDEX idx_tradable_pit_ticker ON sec_gold.tradable_financials_pit (ticker);
CREATE INDEX idx_tradable_pit_date   ON sec_gold.tradable_financials_pit (value_date);
CREATE INDEX idx_tradable_pit_tag    ON sec_gold.tradable_financials_pit (tag);
CREATE INDEX idx_tradable_pit_cik    ON sec_gold.tradable_financials_pit (cik);
