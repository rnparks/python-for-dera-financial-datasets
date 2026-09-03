-- Gold layer: tracked universe crossed with silver facts.
--
-- Two sibling matviews: "latest" for fundamental analysis (restated
-- figures) and "pit" for the as-first-seen figure. Both now carry the
-- availability columns, so a caller can filter on when a fact became
-- actionable rather than on the SEC filing stamp.
--
-- IMPORTANT: neither of these is availability-correct on its own.
-- `tradable_financials_pit` holds one row per fact, the earliest
-- sighting, with no notion of a knowledge date -- iterating over
-- historical dates against it still reads facts that were filed later.
-- Use `sec_gold.fact_asof` and the as_of_* functions for backtests.
-- These two remain for dashboards and for callers that want a single
-- row per fact.
--
-- These query sec_silver.num_silver directly rather than routing
-- through sec_silver.financials() -- the SQL function does not inline
-- cleanly inside a CREATE MATERIALIZED VIEW with joins (the mode-based
-- OR predicate blocks the rank_{pit,latest} index scan), which turned a
-- ~30s build into a >12m build during verification. The filter logic is
-- identical to the function body.
--
-- Company identity now resolves through sec_reference rather than
-- sec_silver.ticker_map. ticker_map holds only currently-registered
-- companies, so joining through it silently deleted every issuer that
-- delisted: 63.6% of 2013 10-K filers, 40.9% of 2019 filers. The
-- crosswalk is dated and keyed on CIK, which is permanent, and the
-- ticker is resolved as a single-valued label so a company holding two
-- share classes cannot duplicate its own facts.
--
-- Known remaining bias: universe_sp1500 is today's membership with no
-- dates, so these views still only see today's index constituents.
-- Fixing that needs a historical constituents source and is tracked
-- separately.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials_pit    CASCADE;

CREATE MATERIALIZED VIEW sec_gold.tradable_financials AS
SELECT
    sec_reference.ticker_at(n.cik, n.tradable_from) AS ticker,
    co.name_latest  AS company_name,
    u.index_name,
    n.cik,
    n.tag,
    n.tlabel        AS metric,
    n.value_date,
    n.filed_date,
    n.known_at,
    n.tradable_from,
    n.qtrs,
    n.uom,
    n.value,
    n.adsh
FROM sec_silver.num_silver         n
JOIN sec_reference.company         co ON co.cik = n.cik
-- One row per company: the universe is joined via a single-valued
-- lookup on the primary ticker, never as a fan-out join.
JOIN LATERAL (
    SELECT u2.index_name
    FROM sec_reference.company_ticker ct
    JOIN sec_silver.universe_sp1500   u2 ON u2.ticker = ct.ticker
    WHERE ct.cik = n.cik
    ORDER BY ct.is_primary DESC, ct.valid_from DESC
    LIMIT 1
) u ON TRUE
WHERE n.rank_latest = 1
  AND n.segments IS NULL
  AND n.coreg    IS NULL;

CREATE INDEX idx_tradable_ticker ON sec_gold.tradable_financials (ticker);
CREATE INDEX idx_tradable_date   ON sec_gold.tradable_financials (value_date);
CREATE INDEX idx_tradable_tag    ON sec_gold.tradable_financials (tag);
CREATE INDEX idx_tradable_cik    ON sec_gold.tradable_financials (cik);
CREATE INDEX idx_tradable_avail  ON sec_gold.tradable_financials (tradable_from);

CREATE MATERIALIZED VIEW sec_gold.tradable_financials_pit AS
SELECT
    sec_reference.ticker_at(n.cik, n.tradable_from) AS ticker,
    co.name_latest  AS company_name,
    u.index_name,
    n.cik,
    n.tag,
    n.tlabel        AS metric,
    n.value_date,
    n.filed_date,
    n.known_at,
    n.tradable_from,
    n.is_original_disclosure,
    n.qtrs,
    n.uom,
    n.value,
    n.adsh
FROM sec_silver.num_silver         n
JOIN sec_reference.company         co ON co.cik = n.cik
JOIN LATERAL (
    SELECT u2.index_name
    FROM sec_reference.company_ticker ct
    JOIN sec_silver.universe_sp1500   u2 ON u2.ticker = ct.ticker
    WHERE ct.cik = n.cik
    ORDER BY ct.is_primary DESC, ct.valid_from DESC
    LIMIT 1
) u ON TRUE
WHERE n.rank_pit = 1
  AND n.segments IS NULL
  AND n.coreg    IS NULL;

CREATE INDEX idx_tradable_pit_ticker ON sec_gold.tradable_financials_pit (ticker);
CREATE INDEX idx_tradable_pit_date   ON sec_gold.tradable_financials_pit (value_date);
CREATE INDEX idx_tradable_pit_tag    ON sec_gold.tradable_financials_pit (tag);
CREATE INDEX idx_tradable_pit_cik    ON sec_gold.tradable_financials_pit (cik);
CREATE INDEX idx_tradable_pit_avail  ON sec_gold.tradable_financials_pit (tradable_from);

COMMENT ON MATERIALIZED VIEW sec_gold.tradable_financials_pit IS
    'As-first-seen value per fact. NOT availability-correct on its own: '
    'it has no knowledge date, so a backtest looping over dates will '
    'read facts filed after the date it simulates. Use fact_asof.';
