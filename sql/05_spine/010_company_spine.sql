-- The company spine and the dated ticker crosswalk.
--
-- `sec_reference.company` is built from the filings themselves, so it
-- is survivorship-free by construction: every CIK that ever filed is
-- here, whether or not the company still exists. This is the durable
-- identity spine. CIK is the join key everywhere because it is
-- permanent and never reused, whereas tickers are recycled between
-- unrelated companies and are therefore unsafe to join on across time.
--
-- `sec_reference.company_ticker` turns the discrete dated sightings in
-- `ticker_observation` into validity intervals. Ticker is a
-- human-readable label hanging off the spine, never an identifier.
--
-- Ordering: this runs as its own stage AFTER `04_reference` and after
-- reference.load_all_reference() has populated universe_sp1500 and
-- ticker_map. It cannot live in 04_reference, because run_sql_dir
-- executes that whole directory before the Python loader fills those
-- tables, and the is_primary rule below reads universe_sp1500. Built a
-- stage too early it would silently see an empty universe and pick the
-- wrong primary ticker for every multi-class company.
--
-- Rebuilding this file alone drops every gold matview (they depend on
-- `company`), so a spine rebuild is always followed by `dera build-gold`.

-- ---------------------------------------------------------------
-- 1. Identity spine: one row per CIK that has ever filed.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.company CASCADE;

CREATE TABLE sec_reference.company AS
SELECT
    s.cik,
    -- Name as of the most recent filing. Names change; this is a label,
    -- and `sub_silver` retains the name used on every historical filing
    -- if you need the name as of a date.
    (ARRAY_AGG(s.name ORDER BY s.filed_date DESC))[1]  AS name_latest,
    (ARRAY_AGG(s.sic  ORDER BY s.filed_date DESC))[1]  AS sic_latest,
    MIN(s.filed_date)                                  AS first_filed,
    MAX(s.filed_date)                                  AS last_filed,
    COUNT(*)                                           AS filing_count,
    bool_or(s.form IN ('10-K', '10-K/A', '10-KT'))     AS ever_filed_10k,
    bool_or(s.form IN ('20-F', '40-F', '20-F/A'))      AS ever_filed_foreign_annual
FROM sec_silver.sub_silver s
GROUP BY s.cik;

ALTER TABLE sec_reference.company ADD PRIMARY KEY (cik);
CREATE INDEX idx_company_last_filed ON sec_reference.company (last_filed);

COMMENT ON TABLE sec_reference.company IS
    'Every CIK that has ever filed. Built from filings, so it contains '
    'delisted, acquired and bankrupt companies. The survivorship-free '
    'identity spine - join on cik, never on ticker.';

-- ---------------------------------------------------------------
-- 2. Capture quality. A capture is evidence of PRESENCE; it is weak
--    evidence of absence, and sometimes no evidence at all.
-- ---------------------------------------------------------------
-- SEC's company_tickers.json is not a stable list, and the archive's
-- captures of it are not all complete. Measured on 81 captures
-- (2018-12 to 2026-09, monthly where the archive has them):
--
--   * June 2020: the file fell from 13,633 rows to 8,223 and 7,879 pairs
--     were never seen again. That is a genuine purge of stale entries --
--     most of them tickers of companies that had delisted years earlier
--     -- and their absence is real.
--   * May-September 2023: the file sat near 9,000 rows for five months
--     and then returned to 10,886. 1,148 pairs vanished on 2023-05-02 and
--     came back in October. That is an artefact: 1,148 companies did not
--     retire and re-adopt the same ticker in the same five months.
--   * October-November 2021: roughly 900 pairs disappeared for two
--     captures and returned in January 2022. Same shape, shorter.
--
-- So "partial" is judged against a window, not the immediate neighbours:
-- a capture holding fewer than 85% of the largest capture within six
-- captures either side is partial. Its sightings still count; its
-- silences cannot close an interval on their own. The table is persisted
-- so the decision is auditable and `dera verify` can report it.
DROP TABLE IF EXISTS sec_reference.ticker_capture CASCADE;

CREATE TABLE sec_reference.ticker_capture AS
SELECT observed_on,
       ROW_NUMBER() OVER (ORDER BY observed_on)::INTEGER AS sn,
       n_rows,
       window_max,
       n_rows < 0.85 * window_max AS is_partial
FROM (
    SELECT observed_on,
           n_rows,
           MAX(n_rows) OVER (ORDER BY observed_on
                             ROWS BETWEEN 6 PRECEDING AND 6 FOLLOWING) AS window_max
    FROM (SELECT observed_on, COUNT(*) AS n_rows
          FROM sec_reference.ticker_observation
          GROUP BY observed_on) c
) s;

ALTER TABLE sec_reference.ticker_capture ADD PRIMARY KEY (observed_on);
CREATE UNIQUE INDEX idx_ticker_capture_sn ON sec_reference.ticker_capture (sn);

COMMENT ON TABLE sec_reference.ticker_capture IS
    'One row per crosswalk capture with its size. is_partial marks a '
    'capture under 85% of the largest capture within six either side; '
    'such a capture proves presence but cannot close an interval alone.';

-- ---------------------------------------------------------------
-- 3. Dated ticker intervals derived from the raw observations.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.company_ticker CASCADE;

CREATE TABLE sec_reference.company_ticker AS
WITH runs AS (
    -- Classic gaps-and-islands: subtracting a per-pair row number from
    -- the global capture number gives a constant per unbroken run of
    -- sightings.
    SELECT o.cik, o.ticker, o.observed_on, s.sn,
           s.sn - ROW_NUMBER() OVER (PARTITION BY o.cik, o.ticker ORDER BY s.sn)
               AS run_key
    FROM sec_reference.ticker_observation o
    JOIN sec_reference.ticker_capture s USING (observed_on)
),
islands AS (
    SELECT cik, ticker,
           MIN(observed_on) AS first_seen,
           MAX(observed_on) AS last_seen,
           MIN(sn)          AS first_sn,
           MAX(sn)          AS last_sn
    FROM runs
    GROUP BY cik, ticker, run_key
),
-- Two bridging rules decide whether a silence between two sightings of
-- the same pair is a real retirement or an artefact of the file:
--
--   (a) the pair is seen again within 200 days. A company that retires
--       a ticker and re-adopts it inside seven months is far rarer than
--       the file dropping and re-adding it, which it demonstrably does in
--       batches of hundreds. Recycling to a DIFFERENT company is not
--       affected: that company gets its own interval, and cik_at()
--       prefers the interval that started later.
--   (b) every capture in the gap is partial, however long the gap, since
--       none of those captures can prove absence.
--
-- Everything else is a real gap and yields two intervals, so a ticker
-- that lapses and is later reissued stays two intervals rather than one
-- falsely continuous one. Measured before this rule on the same
-- observations: 2,562 single-capture gaps and 1,320 two-capture gaps,
-- nearly all in the batches described above.
neighbours AS (
    SELECT i.*,
           LAG(i.last_sn)   OVER (PARTITION BY i.cik, i.ticker ORDER BY i.first_sn)
               AS prev_last_sn,
           LAG(i.last_seen) OVER (PARTITION BY i.cik, i.ticker ORDER BY i.first_sn)
               AS prev_last_seen
    FROM islands i
),
grouped_islands AS (
    SELECT n.*,
           SUM(CASE
                   WHEN n.prev_last_sn IS NULL THEN 1
                   WHEN n.first_seen - n.prev_last_seen <= 200 THEN 0
                   WHEN NOT EXISTS (
                        SELECT 1 FROM sec_reference.ticker_capture g
                        WHERE g.sn > n.prev_last_sn AND g.sn < n.first_sn
                          AND NOT g.is_partial) THEN 0
                   ELSE 1
               END)
               OVER (PARTITION BY n.cik, n.ticker ORDER BY n.first_sn
                     ROWS UNBOUNDED PRECEDING) AS grp
    FROM neighbours n
),
collapsed AS (
    SELECT cik, ticker,
           MIN(first_seen) AS valid_from,
           MAX(last_sn)    AS last_sn
    FROM grouped_islands
    GROUP BY cik, ticker, grp
),
intervals AS (
    SELECT
        c.cik,
        c.ticker,
        c.valid_from,
        -- The first capture after the last sighting: the earliest date
        -- the pair was observed absent. When the pair never reappears
        -- this is the best estimate of retirement whatever the quality
        -- of that capture (the June 2020 purge is the case that proves
        -- it). NULL means present in the most recent capture.
        (SELECT MIN(g.observed_on)
           FROM sec_reference.ticker_capture g
          WHERE g.sn > c.last_sn) AS valid_to
    FROM collapsed c
),
-- A CIK can hold several tickers at once: share classes (GOOG and
-- GOOGL), preferred lines, exchange-traded debt. Joining facts to this
-- table on cik alone would therefore multiply rows -- every Alphabet
-- figure counted twice.
--
-- Rather than drop the extra tickers, which are real and worth keeping,
-- flag exactly one as primary per overlapping run so callers have a
-- safe default. Disjoint runs each get their own primary, so a genuine
-- ticker change over time (TRTC then UNRV on one CIK) keeps a primary
-- in both eras.
merged AS (
    SELECT i.*,
           MAX(COALESCE(i.valid_to, DATE '9999-12-31')) OVER (
               PARTITION BY i.cik ORDER BY i.valid_from
               ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
           ) AS prior_run_end
    FROM intervals i
),
grouped AS (
    SELECT m.*,
           SUM(CASE WHEN m.prior_run_end IS NULL
                      OR m.valid_from >= m.prior_run_end
                    THEN 1 ELSE 0 END)
               OVER (PARTITION BY m.cik ORDER BY m.valid_from
                     ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
               AS overlap_run
    FROM merged m
)
SELECT
    g.cik,
    g.ticker,
    g.valid_from,
    g.valid_to,
    -- Deterministic and documented rather than editorially "right":
    -- prefer a ticker still current, then one that appears in the
    -- tracked universe, then the longest-lived, then alphabetical.
    (ROW_NUMBER() OVER (
        PARTITION BY g.cik, g.overlap_run
        ORDER BY
            (g.valid_to IS NULL) DESC,
            EXISTS (SELECT 1 FROM sec_silver.universe_sp1500 u
                     WHERE u.ticker = g.ticker) DESC,
            (COALESCE(g.valid_to, CURRENT_DATE) - g.valid_from) DESC,
            g.ticker ASC
    ) = 1) AS is_primary
FROM grouped g;

ALTER TABLE sec_reference.company_ticker
    ADD PRIMARY KEY (cik, ticker, valid_from);
CREATE INDEX idx_compticker_cik    ON sec_reference.company_ticker (cik);
CREATE INDEX idx_compticker_ticker ON sec_reference.company_ticker (ticker);
CREATE INDEX idx_compticker_range  ON sec_reference.company_ticker (valid_from, valid_to);
-- Partial index: the safe single-row lookup path.
CREATE INDEX idx_compticker_primary ON sec_reference.company_ticker (cik, valid_from)
    WHERE is_primary;

COMMENT ON TABLE sec_reference.company_ticker IS
    'Dated CIK/ticker intervals. Ticker as of date D: '
    'valid_from <= D AND (valid_to IS NULL OR valid_to > D). '
    'Coverage begins 2019-02 - the archive has nothing earlier, so '
    'companies delisted before then have no ticker here.';
COMMENT ON COLUMN sec_reference.company_ticker.valid_to IS
    'First capture in which the pair was absent, i.e. the earliest date '
    'it was observed gone. NULL means present in the latest capture. A '
    'silence followed by a sighting within 200 days, or made only of '
    'partial captures, is bridged rather than closed; see ticker_capture.';

-- ---------------------------------------------------------------
-- 4. Convenience view: the ticker to show for a CIK today.
-- ---------------------------------------------------------------
CREATE OR REPLACE VIEW sec_reference.company_label AS
SELECT
    co.cik,
    co.name_latest,
    co.sic_latest,
    co.first_filed,
    co.last_filed,
    co.ever_filed_10k,
    -- Most recent known ticker, current or not, purely for display.
    (SELECT ct.ticker
       FROM sec_reference.company_ticker ct
      WHERE ct.cik = co.cik
      ORDER BY ct.is_primary DESC, ct.valid_to IS NULL DESC, ct.valid_from DESC
      LIMIT 1)                                   AS ticker_latest,
    EXISTS (SELECT 1 FROM sec_reference.company_ticker ct
             WHERE ct.cik = co.cik AND ct.valid_to IS NULL) AS ticker_is_current
FROM sec_reference.company co;

COMMENT ON VIEW sec_reference.company_label IS
    'Human-readable label for a CIK. ticker_latest is for display only; '
    'use company_ticker with a date for any as-of join.';


-- ---------------------------------------------------------------
-- 5. As-of resolvers. Both return at most one row, so they can be
--    used inline without any risk of fanning out a fact join.
-- ---------------------------------------------------------------

CREATE OR REPLACE FUNCTION sec_reference.ticker_at(p_cik INTEGER, p_asof DATE)
RETURNS TEXT
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT ct.ticker
    FROM sec_reference.company_ticker ct
    WHERE ct.cik = p_cik
      AND ct.valid_from <= p_asof
      AND (ct.valid_to > p_asof OR ct.valid_to IS NULL)
    ORDER BY ct.is_primary DESC, ct.valid_from DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_reference.ticker_at(INTEGER, DATE) IS
    'The ticker to display for this company on this date, or NULL if '
    'none is known. Single-valued: safe to call inline.';

CREATE OR REPLACE FUNCTION sec_reference.cik_at(p_ticker TEXT, p_asof DATE)
RETURNS INTEGER
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT ct.cik
    FROM sec_reference.company_ticker ct
    WHERE ct.ticker = REPLACE(UPPER(TRIM(p_ticker)), '.', '-')
      AND ct.valid_from <= p_asof
      AND (ct.valid_to > p_asof OR ct.valid_to IS NULL)
    ORDER BY ct.is_primary DESC, ct.valid_from DESC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_reference.cik_at(TEXT, DATE) IS
    'Which company held this ticker on this date, or NULL if the '
    'crosswalk has no interval covering it (coverage starts 2019-02). '
    'Tickers are recycled between unrelated companies, so resolving '
    'without a date is unsafe for any historical query.';

-- The strict variant, for callers that would otherwise pass a NULL CIK
-- straight through and return a full set of empty rows. The README once
-- showed as_of_snapshot('AAPL', DATE '2015-06-30') as the headline
-- example; it returned fifteen rows and no values, because 2015 is
-- before the crosswalk floor and nothing said so. An error says so.
CREATE OR REPLACE FUNCTION sec_reference.cik_at_strict(p_ticker TEXT, p_asof DATE)
RETURNS INTEGER
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cik INTEGER;
BEGIN
    v_cik := sec_reference.cik_at(p_ticker, p_asof);
    IF v_cik IS NULL THEN
        RAISE EXCEPTION 'No company held ticker % on %. The crosswalk '
            'covers 2019-02 onward; for earlier dates resolve the CIK '
            'yourself and call the CIK-keyed function.',
            p_ticker, p_asof
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_cik;
END;
$$;

COMMENT ON FUNCTION sec_reference.cik_at_strict(TEXT, DATE) IS
    'cik_at() that raises instead of returning NULL. Used by the '
    'ticker-keyed as_of_* wrappers so an unresolvable ticker is an error '
    'rather than a silent set of empty rows.';
