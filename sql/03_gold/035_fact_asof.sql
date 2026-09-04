-- The availability-correct fact table. This is what backtests read.
--
-- Unlike the two tradable_financials matviews, which collapse each fact
-- to a single chosen vintage, this keeps EVERY vintage as its own
-- observation. Nothing is overwritten by a later restatement, which is
-- what makes "reproduce what an investor could have known on date T"
-- answerable rather than approximated.
--
-- The query shape is a half-open interval scan:
--
--   WHERE tradable_from <= T
--     AND (superseded_tradable > T OR superseded_tradable IS NULL)
--
-- which yields exactly one row per fact key: the newest vintage that
-- had already become actionable by T. No window function, no DISTINCT
-- ON, no correlated subquery.
--
-- Every row carries its source filing, the instant it became public and
-- the fiscal period it describes, so any figure can be traced back to
-- the document that disclosed it.
--
-- Size: roughly 2x a single-vintage matview. Retaining the full
-- restatement history is cheap; the GE example alone justifies it,
-- where fiscal 2022 revenue reads $76.6B as first filed and $29.1B
-- after restatement.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.fact_asof CASCADE;

CREATE MATERIALIZED VIEW sec_gold.fact_asof AS
SELECT
    n.cik,
    co.name_latest          AS company_name,
    -- Carried here so a cross-sectional as-of screen can group by
    -- sector without re-joining 98M rows back to the universe.
    -- Resolved once per company, not as of a date: the universe is a
    -- present-day snapshot with no classification history.
    u.gics_sector,
    u.gics_sub_industry,
    n.tag,
    n.tlabel                AS metric,
    n.value_date,
    n.qtrs,
    n.uom,
    n.value,
    -- provenance
    n.adsh,
    n.form,
    n.filed_date,
    -- availability
    n.known_at,
    n.tradable_from,
    n.superseded_tradable,
    n.vintage_seq,
    n.is_original_disclosure
FROM sec_silver.num_silver n
JOIN sec_reference.company co ON co.cik = n.cik
-- Single-valued: at most one row, so this cannot multiply facts even
-- for a company holding several share classes.
LEFT JOIN LATERAL (
    SELECT u2.gics_sector, u2.gics_sub_industry
    FROM sec_reference.company_ticker ct2
    JOIN sec_silver.universe_sp1500   u2 ON u2.ticker = ct2.ticker
    WHERE ct2.cik = n.cik
    ORDER BY ct2.is_primary DESC, ct2.valid_from DESC
    LIMIT 1
) u ON TRUE
WHERE n.segments IS NULL
  AND n.coreg    IS NULL
  -- DERA carries filer typos: value_dates as early as 1980 and as late
  -- as 2031, published as-is by SEC. Left unbounded they distort any
  -- aggregate keyed on date. Bounded generously so real restatements of
  -- old periods survive.
  AND n.value_date >= DATE '2005-01-01'
  AND n.value_date <= CURRENT_DATE + INTERVAL '1 year';

-- The interval scan above is the hot path: company, concept, period,
-- then the two availability bounds.
CREATE INDEX idx_factasof_lookup ON sec_gold.fact_asof
    (cik, tag, value_date, qtrs, tradable_from, superseded_tradable);
-- Cross-sectional slices: "everything actionable on date T".
CREATE INDEX idx_factasof_window ON sec_gold.fact_asof
    (tradable_from, superseded_tradable);
CREATE INDEX idx_factasof_tag    ON sec_gold.fact_asof (tag, value_date);
CREATE INDEX idx_factasof_cik    ON sec_gold.fact_asof (cik);
CREATE INDEX idx_factasof_sector ON sec_gold.fact_asof (gics_sector, tradable_from);

COMMENT ON MATERIALIZED VIEW sec_gold.fact_asof IS
    'Bitemporal fact table: one row per (fact, filing). Every vintage '
    'retained. Slice with tradable_from <= T AND (superseded_tradable > '
    'T OR superseded_tradable IS NULL) for exactly one row per fact.';
COMMENT ON COLUMN sec_gold.fact_asof.superseded_tradable IS
    'When the next vintage of this fact became actionable. NULL means '
    'this vintage still stands.';
