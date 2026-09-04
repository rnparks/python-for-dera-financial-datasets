-- Gold layer: index constituents crossed with silver facts.
--
-- Two sibling matviews: "latest" for fundamental analysis (restated
-- figures) and "pit" for the earliest-sighting figure. Both carry the
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
-- TICKER RESOLUTION. The crosswalk is a range join on
-- sec_reference.company_ticker, provably single-valued (no CIK has two
-- overlapping primary intervals), resolved as of each fact's own
-- availability date and coalesced to the company's best-known symbol
-- where the crosswalk (2019 onward) has nothing; `ticker_is_asof` says
-- which you got.
--
-- INDEX MEMBERSHIP IS DATED. The population is every company that has
-- ever had an interval in sec_reference.index_membership -- the
-- replayed S&P 500 history plus today's S&P 400 and 600 snapshots -- and
-- each fact carries the index and GICS classification AS OF its
-- tradable_from, with `index_is_asof` saying whether an interval really
-- covered that date or the company's latest membership was used as a
-- label. Before this the population was today's S&P 1500 only, so every
-- company that had left an index -- SVB Financial, Sears, Bed Bath &
-- Beyond -- was absent, and NVIDIA's 2010 facts wore its 2026
-- classification.
--
-- For the S&P 400 and 600 the membership is a single interval from
-- 1900-01-01 labelled current_snapshot, which is exactly the old
-- survivorship-biased state, confined to two indexes and labelled;
-- `index_is_asof` is TRUE for them at every date until their history is
-- replayed, and peer_stats treats them accordingly.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials        CASCADE;
DROP MATERIALIZED VIEW IF EXISTS sec_gold.tradable_financials_pit    CASCADE;

CREATE MATERIALIZED VIEW sec_gold.tradable_financials AS
SELECT
    COALESCE(ct.ticker, cl.ticker_latest)  AS ticker,
    (ct.ticker IS NOT NULL)                AS ticker_is_asof,
    co.name_latest                         AS company_name,
    COALESCE(asof.index_name, latest.index_name)               AS index_name,
    (asof.index_name IS NOT NULL)                              AS index_is_asof,
    COALESCE(asof.gics_sector, latest.gics_sector)             AS gics_sector,
    COALESCE(asof.gics_sub_industry, latest.gics_sub_industry) AS gics_sub_industry,
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
LEFT JOIN sec_reference.company_ticker ct
       ON ct.cik = n.cik
      AND ct.is_primary
      AND ct.valid_from <= n.tradable_from
      AND (ct.valid_to > n.tradable_from OR ct.valid_to IS NULL)
-- Membership AS OF the fact: replayed history beats a snapshot when
-- both cover the date (a company now in the 400 that was in the 500).
LEFT JOIN LATERAL (
    SELECT m.index_name, m.gics_sector, m.gics_sub_industry
    FROM sec_reference.index_membership m
    WHERE m.cik = n.cik
      AND m.valid_from <= n.tradable_from
      AND (m.valid_to IS NULL OR m.valid_to > n.tradable_from)
    ORDER BY (m.source = 'wikipedia_history') DESC, m.valid_from DESC
    LIMIT 1
) asof ON TRUE
-- The label fallback, and the population filter: a company with no
-- membership at all is not in these views.
JOIN sec_reference.index_membership_latest latest ON latest.cik = n.cik
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
    COALESCE(asof.index_name, latest.index_name)               AS index_name,
    (asof.index_name IS NOT NULL)                              AS index_is_asof,
    COALESCE(asof.gics_sector, latest.gics_sector)             AS gics_sector,
    COALESCE(asof.gics_sub_industry, latest.gics_sub_industry) AS gics_sub_industry,
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
LEFT JOIN LATERAL (
    SELECT m.index_name, m.gics_sector, m.gics_sub_industry
    FROM sec_reference.index_membership m
    WHERE m.cik = n.cik
      AND m.valid_from <= n.tradable_from
      AND (m.valid_to IS NULL OR m.valid_to > n.tradable_from)
    ORDER BY (m.source = 'wikipedia_history') DESC, m.valid_from DESC
    LIMIT 1
) asof ON TRUE
JOIN sec_reference.index_membership_latest latest ON latest.cik = n.cik
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
    'Earliest-sighting value per fact. NOT availability-correct on its '
    'own: it has no knowledge date, so a backtest looping over dates will '
    'read facts filed after the date it simulates. Use fact_asof.';
COMMENT ON COLUMN sec_gold.tradable_financials.ticker_is_asof IS
    'TRUE when the ticker was resolved as of this fact''s own '
    'availability date. FALSE means the crosswalk had no interval '
    'covering it (it predates 2019) and this is the company''s '
    'best-known symbol instead.';
COMMENT ON COLUMN sec_gold.tradable_financials.index_name IS
    'Index the company belonged to as of tradable_from (SP500 from '
    'replayed history; SP400/SP600 from today''s snapshot at every date). '
    'When no interval covers the date, the company''s latest membership, '
    'and index_is_asof is FALSE.';
COMMENT ON COLUMN sec_gold.tradable_financials.index_is_asof IS
    'TRUE when a membership interval covers tradable_from. FALSE means '
    'the company was not a constituent then and index_name / GICS are '
    'labels from its latest membership.';
COMMENT ON COLUMN sec_gold.tradable_financials.gics_sector IS
    'GICS sector as of tradable_from where the membership history has '
    'it (S&P 500), else the latest classification.';
