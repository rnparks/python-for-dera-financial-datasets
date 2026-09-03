-- Master numeric fact table: bitemporal, one row per (fact, filing).
--
-- Two time axes, kept strictly separate:
--
--   value_date                 -- the fiscal period the number describes
--   known_at / tradable_from   -- when the number became knowable / actionable
--
-- Every vintage of every fact is retained. Nothing is overwritten by a
-- later restatement. Asking "what did we believe about FY2022 revenue on
-- date T" is then a range scan over the validity interval rather than a
-- window function at query time:
--
--   WHERE tradable_from <= T
--     AND (superseded_tradable > T OR superseded_tradable IS NULL)
--
-- which returns exactly one row per fact key.
--
-- rank_pit and rank_latest are retained as convenience shortcuts for
-- existing callers, but note what rank_pit actually means: "earliest
-- sighting in this dataset", NOT "as originally filed". Coverage begins
-- 2009-04-15, and registration statements backfill years of history, so
-- 27.8% of rank_pit=1 annual rows are prior-period comparatives rather
-- than original disclosures. is_original_disclosure separates them. The
-- as-of interval above is the correct backtest entry point.
--
-- Work-mem sized for the window-function sorts over ~185M num_raw rows.
-- At default 4MB postgres spills to 90+GB of temp files and the build
-- takes hours; at 2GB the sorts stay mostly in memory. SET LOCAL reverts
-- at transaction end -- note run_sql_dir shares one transaction across a
-- directory, so this leaks forward to later files in 02_silver.
SET LOCAL work_mem             = '2GB';
SET LOCAL maintenance_work_mem = '2GB';

CREATE TABLE sec_silver.num_silver AS
WITH raw_typed AS (
    SELECT
        n.adsh,
        s.cik,
        n.tag,
        n.version,
        n.ddate::DATE                                AS value_date,
        n.qtrs::INTEGER                              AS qtrs,
        n.uom,
        n.coreg,
        NULLIF(n.segments, '')                       AS segments,
        -- Strict numeric grammar: optional sign, digits with optional
        -- fraction (or a bare fraction), optional exponent.
        --
        -- The previous pattern '^[0-9\.\-]+$' was a character class, so
        -- it accepted '-', '.', '1.2.3' and '1-2' -- each of which then
        -- raises "invalid input syntax for type numeric" on cast and
        -- aborts the whole build -- while rejecting scientific notation
        -- outright. A scan of all 185M bronze rows found zero of either
        -- case, so this is insurance against a future quarter rather
        -- than a fix for present corruption, but the failure mode it
        -- prevents is a hard abort 30 minutes into a rebuild.
        CASE
            WHEN n.value ~ '^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
            THEN n.value::NUMERIC
            ELSE NULL
        END                                          AS value,
        n.footnote,
        s.filed_date,
        s.known_at,
        s.tradable_from,
        s.period_date,
        s.form
    FROM sec_raw.num_raw n
    JOIN sec_silver.sub_silver s ON n.adsh = s.adsh
)
SELECT
    r.adsh,
    r.cik,
    r.tag,
    r.version,
    t.tlabel,
    r.value_date,
    r.qtrs,
    r.uom,
    r.coreg,
    r.segments,
    r.value,
    r.footnote,
    r.filed_date,
    r.known_at,
    r.tradable_from,
    r.form,
    -- True when the filing carrying this fact actually reports on the
    -- period the fact describes, rather than repeating it as a
    -- comparative. The 100-day tolerance absorbs the gap between a
    -- period end and the filing that closes it.
    (r.period_date - r.value_date) <= 100             AS is_original_disclosure,
    -- Vintage 1 is the first sighting, 2 the first restatement, and so
    -- on. Ordering by known_at rather than filed_date matters: 342,945
    -- fact keys have two filings sharing a filed_date, where the old
    -- `adsh ASC` fallback picked essentially at random.
    ROW_NUMBER() OVER w_asc                           AS vintage_seq,
    -- The moment this vintage stopped being current, i.e. when the next
    -- filing restated it. NULL means it still stands. Together with
    -- known_at/tradable_from these form a half-open validity interval.
    LEAD(r.known_at)      OVER w_asc                  AS superseded_known_at,
    LEAD(r.tradable_from) OVER w_asc                  AS superseded_tradable,
    ROW_NUMBER() OVER w_asc                           AS rank_pit,
    -- Derived from the ascending window rather than a second descending
    -- sort: identical result, one fewer sort over 185M rows.
    (COUNT(*) OVER w_part - ROW_NUMBER() OVER w_asc + 1)::BIGINT
                                                      AS rank_latest
FROM raw_typed r
LEFT JOIN sec_silver.tag_silver t
    ON r.tag = t.tag AND r.version = t.version
WINDOW
    w_part AS (
        PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
    ),
    w_asc AS (
        PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
        ORDER BY r.known_at ASC, r.adsh ASC
    );

CREATE INDEX idx_num_cik_tag      ON sec_silver.num_silver (cik, tag);
CREATE INDEX idx_num_rank_pit     ON sec_silver.num_silver (rank_pit);
CREATE INDEX idx_num_rank_latest  ON sec_silver.num_silver (rank_latest);

-- Serves the as-of interval predicate for a single company/concept,
-- which is the shape every backtest lookup takes.
CREATE INDEX idx_num_asof ON sec_silver.num_silver
    (cik, tag, value_date, qtrs, tradable_from, superseded_tradable);

-- Serves cross-sectional as-of slices ("everything knowable on date T").
CREATE INDEX idx_num_tradable_from ON sec_silver.num_silver (tradable_from);

COMMENT ON COLUMN sec_silver.num_silver.filed_date IS
    'SEC official filing date. Provenance and reconciliation only. '
    'NOT an availability date - use tradable_from. Wrong for ~48% of '
    'filings, which are accepted after the close yet stamped that day.';
COMMENT ON COLUMN sec_silver.num_silver.known_at IS
    'Instant this fact became publicly readable on EDGAR.';
COMMENT ON COLUMN sec_silver.num_silver.tradable_from IS
    'First NYSE session an investor could act on this fact. The correct '
    'join key for backtests.';
COMMENT ON COLUMN sec_silver.num_silver.superseded_tradable IS
    'tradable_from of the next vintage of this same fact, or NULL if '
    'this vintage still stands. Gives a half-open interval so an as-of '
    'slice returns exactly one row per fact key.';
COMMENT ON COLUMN sec_silver.num_silver.is_original_disclosure IS
    'FALSE when this filing reports the period only as a prior-period '
    'comparative. 27.8% of rank_pit=1 annual rows are backfills, mostly '
    'pre-2011 (dataset starts 2009-04-15) and IPO registration '
    'statements.';
COMMENT ON COLUMN sec_silver.num_silver.rank_pit IS
    'Earliest sighting in THIS DATASET, not necessarily as originally '
    'filed. See is_original_disclosure. Prefer the tradable_from / '
    'superseded_tradable interval for backtests.';
