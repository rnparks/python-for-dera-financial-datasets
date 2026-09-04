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
    -- As of the fact's availability date where the membership history
    -- has a classification for it (the replayed S&P 500), else the
    -- company's latest known classification, else NULL for a company
    -- that was never in an index.
    COALESCE(asof.gics_sector, latest.gics_sector)             AS gics_sector,
    COALESCE(asof.gics_sub_industry, latest.gics_sub_industry) AS gics_sub_industry,
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
-- The timeline never overlaps (05_spine/020, section 3c), so this join
-- is single-valued and cannot multiply facts; being a plain join rather
-- than a per-fact LATERAL is what keeps this 33 GB build hashable.
LEFT JOIN sec_reference.index_membership_timeline asof
       ON asof.cik = n.cik
      AND asof.valid_from <= n.tradable_from
      AND (asof.valid_to IS NULL OR asof.valid_to > n.tradable_from)
LEFT JOIN sec_reference.index_membership_latest latest ON latest.cik = n.cik
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
-- No cik-only index: cik leads idx_factasof_lookup, which serves every
-- per-company predicate. The separate one was 653 MB of duplicate work.
CREATE INDEX idx_factasof_sector ON sec_gold.fact_asof (gics_sector, tradable_from);

COMMENT ON MATERIALIZED VIEW sec_gold.fact_asof IS
    'Bitemporal fact table: one row per (fact, filing). Every vintage '
    'retained. Slice with tradable_from <= T AND (superseded_tradable > '
    'T OR superseded_tradable IS NULL) for exactly one row per fact.';
COMMENT ON COLUMN sec_gold.fact_asof.superseded_tradable IS
    'When the next vintage of this fact became actionable. NULL means '
    'this vintage still stands.';
