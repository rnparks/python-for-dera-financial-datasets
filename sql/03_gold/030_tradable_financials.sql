-- Gold layer: tracked universe crossed with silver facts.
--
-- Two sibling matviews: "latest" for fundamental analysis (restated
-- figures) and "pit" for the as-first-seen figure. Both carry the
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
-- TICKER RESOLUTION. Two things were wrong in the previous version and
-- both are fixed here.
--
-- It called sec_reference.ticker_at() once per row across ~12M rows in
-- each matview, which is a per-row indexed lookup where a range join
-- does the same work in one pass. That is the bulk of why the gold
-- build took 39 minutes rather than about one.
--
-- Worse, resolving the ticker as of each fact's own availability date
-- meant every fact older than the crosswalk's 2019-02 coverage floor
-- resolved to NULL: 5,510,776 rows, 47.6% of the matview, had no
-- ticker at all. For a display label that trade is backwards, so the
-- as-of value is now coalesced to the company's best-known ticker and
-- `ticker_is_asof` records which one you got. A false there means the
-- label is today's symbol attached to an older fact.
--
-- The range join is provably single-valued: no CIK has two overlapping
-- primary intervals. Companies do hold several primary intervals over
-- time (2,623 hold two) but they are disjoint, so at most one matches.
--
-- GICS is resolved once per company, NOT as of a date. universe_sp1500
-- is a current Wikipedia snapshot with no history, so varying the
-- classification over time would be inventing data it does not have.
--
-- Known remaining bias: that same universe is today's membership, so
-- these views still see only today's index constituents. Fixing it
-- needs a historical constituents source and is tracked separately.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials_pit    CASCADE;

CREATE MATERIALIZED VIEW sec_gold.tradable_financials AS
SELECT
    COALESCE(ct.ticker, cl.ticker_latest)  AS ticker,
    (ct.ticker IS NOT NULL)                AS ticker_is_asof,
    co.name_latest                         AS company_name,
    u.index_name,
    u.gics_sector,
    u.gics_sub_industry,
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
FROM sec_silver.num_silver          n
JOIN sec_reference.company          co ON co.cik = n.cik
JOIN sec_reference.company_label    cl ON cl.cik = n.cik
-- Single pass, at most one match per row.
LEFT JOIN sec_reference.company_ticker ct
       ON ct.cik = n.cik
      AND ct.is_primary
      AND ct.valid_from <= n.tradable_from
      AND (ct.valid_to > n.tradable_from OR ct.valid_to IS NULL)
-- Universe attributes, resolved per company rather than per row.
JOIN LATERAL (
    SELECT u2.index_name, u2.gics_sector, u2.gics_sub_industry
    FROM sec_reference.company_ticker ct2
    JOIN sec_silver.universe_sp1500   u2 ON u2.ticker = ct2.ticker
    WHERE ct2.cik = n.cik
    ORDER BY ct2.is_primary DESC, ct2.valid_from DESC
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
CREATE INDEX idx_tradable_sector ON sec_gold.tradable_financials (gics_sector);

CREATE MATERIALIZED VIEW sec_gold.tradable_financials_pit AS
SELECT
    COALESCE(ct.ticker, cl.ticker_latest)  AS ticker,
    (ct.ticker IS NOT NULL)                AS ticker_is_asof,
    co.name_latest                         AS company_name,
    u.index_name,
    u.gics_sector,
    u.gics_sub_industry,
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
FROM sec_silver.num_silver          n
JOIN sec_reference.company          co ON co.cik = n.cik
JOIN sec_reference.company_label    cl ON cl.cik = n.cik
LEFT JOIN sec_reference.company_ticker ct
       ON ct.cik = n.cik
      AND ct.is_primary
      AND ct.valid_from <= n.tradable_from
      AND (ct.valid_to > n.tradable_from OR ct.valid_to IS NULL)
JOIN LATERAL (
    SELECT u2.index_name, u2.gics_sector, u2.gics_sub_industry
    FROM sec_reference.company_ticker ct2
    JOIN sec_silver.universe_sp1500   u2 ON u2.ticker = ct2.ticker
    WHERE ct2.cik = n.cik
    ORDER BY ct2.is_primary DESC, ct2.valid_from DESC
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
CREATE INDEX idx_tradable_pit_sector ON sec_gold.tradable_financials_pit (gics_sector);

COMMENT ON MATERIALIZED VIEW sec_gold.tradable_financials_pit IS
    'As-first-seen value per fact. NOT availability-correct on its own: '
    'it has no knowledge date, so a backtest looping over dates will '
    'read facts filed after the date it simulates. Use fact_asof.';
COMMENT ON COLUMN sec_gold.tradable_financials.ticker_is_asof IS
    'TRUE when the ticker was resolved as of this fact''s own '
    'availability date. FALSE means the crosswalk had no interval '
    'covering it (it predates 2019-02) and this is the company''s '
    'best-known symbol instead.';
COMMENT ON COLUMN sec_gold.tradable_financials.gics_sector IS
    'Current GICS sector. Point-in-time classification is not '
    'available: the universe is a present-day snapshot with no history.';
