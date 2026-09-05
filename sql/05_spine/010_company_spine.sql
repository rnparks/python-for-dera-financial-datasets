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
-- `ticker_observation` into validity intervals (source = 'observed'),
-- then carries one safe shape of history back to the company's first
-- filing (source = 'extended', section 3b). Ticker is a human-readable
-- label hanging off the spine, never an identifier.
--
-- Ordering: this runs as its own stage AFTER `04_reference` and after
-- reference.load_all_reference() has populated universe_sp1500 and
-- ticker_map. It cannot live in 04_reference, because run_sql_dir
-- executes that whole directory before the Python loader fills those
-- tables, and the is_primary rule below reads universe_sp1500. Built a
-- stage too early it would silently see an empty universe and pick the
-- wrong primary ticker for every multi-class company.
--
-- Every table here is declared with CREATE TABLE IF NOT EXISTS and
-- refilled in place (TRUNCATE, then INSERT), so a rebuild keeps the gold
-- matviews -- which depend on `company` and `company_ticker` -- alive;
-- `dera rebuild-reference` then refreshes only the matviews whose inputs
-- actually changed. This file used to DROP ... CASCADE, which took every
-- gold matview with it and turned a two-minute crosswalk change into a
-- 32-minute gold rebuild. A column change still needs the drop:
-- `dera rebuild-reference --recreate-spine` does it on purpose.

-- ---------------------------------------------------------------
-- 1. Identity spine: one row per CIK that has ever filed.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec_reference.company (
    cik                       INTEGER PRIMARY KEY,
    name_latest               TEXT,
    sic_latest                INTEGER,
    first_filed               DATE,
    last_filed                DATE,
    filing_count              BIGINT,
    ever_filed_10k            BOOLEAN,
    ever_filed_foreign_annual BOOLEAN
);
CREATE INDEX IF NOT EXISTS idx_company_last_filed ON sec_reference.company (last_filed);

TRUNCATE sec_reference.company;
INSERT INTO sec_reference.company
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
CREATE TABLE IF NOT EXISTS sec_reference.ticker_capture (
    observed_on DATE PRIMARY KEY,
    sn          INTEGER,
    n_rows      BIGINT,
    window_max  BIGINT,
    is_partial  BOOLEAN
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_ticker_capture_sn ON sec_reference.ticker_capture (sn);

TRUNCATE sec_reference.ticker_capture;
INSERT INTO sec_reference.ticker_capture
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

COMMENT ON TABLE sec_reference.ticker_capture IS
    'One row per crosswalk capture with its size. is_partial marks a '
    'capture under 85% of the largest capture within six either side; '
    'such a capture proves presence but cannot close an interval alone.';

-- ---------------------------------------------------------------
-- 3. Dated ticker intervals derived from the raw observations.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec_reference.company_ticker (
    cik        INTEGER NOT NULL,
    ticker     TEXT    NOT NULL,
    valid_from DATE    NOT NULL,
    valid_to   DATE,
    is_primary BOOLEAN,
    source     TEXT,
    PRIMARY KEY (cik, ticker, valid_from)
);
CREATE INDEX IF NOT EXISTS idx_compticker_cik    ON sec_reference.company_ticker (cik);
CREATE INDEX IF NOT EXISTS idx_compticker_ticker ON sec_reference.company_ticker (ticker);
CREATE INDEX IF NOT EXISTS idx_compticker_range  ON sec_reference.company_ticker (valid_from, valid_to);
-- Partial index: the safe single-row lookup path.
CREATE INDEX IF NOT EXISTS idx_compticker_primary ON sec_reference.company_ticker (cik, valid_from)
    WHERE is_primary;

TRUNCATE sec_reference.company_ticker;
INSERT INTO sec_reference.company_ticker
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
    ) = 1) AS is_primary,
    'observed'::TEXT AS source
FROM grouped g;

-- ---------------------------------------------------------------
-- 3b. Back-extension before the archive floor.
-- ---------------------------------------------------------------
-- The archive's first capture is 2018-12-26 and its first FULL-SIZE
-- capture is 2019-10-02 (the first holding 85% of the all-time maximum;
-- the earlier ones are the file being partially indexed, not the world
-- being smaller). Every pair alive on that floor is left-censored: the
-- company held the ticker before anything could see it, and every fact
-- from 2009 to 2019 -- half the panel -- carried a fallback label.
--
-- One shape of history is safe enough to publish, flagged:
--
--   * the CIK has exactly ONE distinct primary ticker across its whole
--     observed history. Preferred lines, notes and warrants are
--     non-primary and do not disqualify it (JPMorgan has seventeen
--     tickers and one primary; Prudential's PFK and PJH are notes, not
--     former names). A ticker CHANGE does disqualify it, because the
--     change cannot be dated from this evidence: Meta is FB then META
--     and gets nothing before 2018-12;
--   * that ticker was seen on or before the floor, so its start is the
--     archive's start, not the company's;
--   * the company filed with EDGAR before the first sighting. The
--     extension runs from `company.first_filed` -- a floor on existence,
--     not a trading date; the listing derivation clips it to
--     first_trade_date as it does every interval;
--   * no other CIK was observed holding the same ticker earlier in the
--     window. 86 candidates fail this, every one a stale-file artefact
--     (Alcoa Inc still listed against AA in the December 2018 file while
--     Alcoa Corp had held it since 2016): the extension would have to
--     start at the other holder's last sighting, which is the floor
--     itself, so nothing is written and the pre-2019 label stays a
--     flagged fallback.
--
-- Measured 2026-09-04: 6,405 CIKs qualify, 2,108 of them already
-- delisted when first seen (the file was stale, which is exactly what
-- makes the inference possible). cik_at('AAPL', DATE '2015-06-30')
-- resolves because of this block. Every as-of flag downstream
-- (ticker_is_asof, price_ticker_is_asof, universe_at) stays TRUE only
-- for observed intervals; an extended label is an inference and says so.
INSERT INTO sec_reference.company_ticker (cik, ticker, valid_from, valid_to, is_primary, source)
WITH floor AS (
    SELECT MIN(observed_on) AS floor_date
    FROM sec_reference.ticker_capture
    WHERE n_rows >= 0.85 * (SELECT MAX(n_rows) FROM sec_reference.ticker_capture)
),
primaries AS (
    SELECT ct.cik,
           COUNT(DISTINCT ct.ticker) AS n_primary,
           MIN(ct.ticker)            AS ticker,
           MIN(ct.valid_from)        AS first_seen
    FROM sec_reference.company_ticker ct
    WHERE ct.is_primary
    GROUP BY ct.cik
),
candidates AS (
    SELECT p.cik, p.ticker, p.first_seen,
           GREATEST(co.first_filed,
                    (SELECT COALESCE(MAX(COALESCE(o.valid_to, DATE '9999-12-31')), co.first_filed)
                       FROM sec_reference.company_ticker o
                      WHERE o.ticker = p.ticker
                        AND o.cik <> p.cik
                        AND o.valid_from < p.first_seen)) AS valid_from
    FROM primaries p
    CROSS JOIN floor f
    JOIN sec_reference.company co ON co.cik = p.cik
    WHERE p.n_primary = 1
      AND p.first_seen <= f.floor_date
      AND co.first_filed < p.first_seen
)
SELECT c.cik, c.ticker, c.valid_from, c.first_seen, TRUE, 'extended'
FROM candidates c
WHERE c.valid_from < c.first_seen;

COMMENT ON TABLE sec_reference.company_ticker IS
    'Dated CIK/ticker intervals. Ticker as of date D: '
    'valid_from <= D AND (valid_to IS NULL OR valid_to > D). '
    'Observed intervals begin 2018-12 (the archive has nothing earlier); '
    'source = ''extended'' rows carry a single-ticker history back to '
    'the company''s first filing and are inferred, not observed.';
COMMENT ON COLUMN sec_reference.company_ticker.source IS
    '''observed'': derived from dated sightings of company_tickers.json. '
    '''extended'': inferred backwards from the first sighting to the '
    'company''s first filing, only where the CIK has ever had one primary '
    'ticker and no other CIK was seen holding it earlier. Every as-of '
    'flag downstream is TRUE for observed rows only.';
COMMENT ON COLUMN sec_reference.company_ticker.valid_to IS
    'First capture in which the pair was absent, i.e. the earliest date '
    'it was observed gone. NULL means present in the latest capture. A '
    'silence followed by a sighting within 200 days, or made only of '
    'partial captures, is bridged rather than closed; see ticker_capture.';

-- ---------------------------------------------------------------
-- 3c. CIK succession: one company, two registrants.
-- ---------------------------------------------------------------
-- A holding-company reorganisation gives a company a new CIK. The old
-- registrant may go silent (Cigna 701221 -> 1739940 in 2018, WestRock
-- 1636023 -> 1732845, BlackRock 1364742 -> 2012383 in 2024) or keep
-- filing as a subsidiary (Apache 6769 kept filing after APA Corp 1841666
-- took the ticker in 2021). The index pages know only one CIK per
-- ticker, so a membership run resolved to one registrant would either
-- name a CIK that did not exist yet or one that had stopped filing:
-- five S&P 500 constituents scored nothing on 2020-06-30 for that reason.
-- The evidence of succession is the ticker handoff in SEC's own file: a
-- primary ticker held by one CIK whose interval ends where another,
-- newer CIK's interval for the same ticker begins. A recycled ticker
-- between unrelated companies looks the same here (CalAmp's CAMP went
-- to CAMP4 Therapeutics four months after it delisted), which is why
-- this table is evidence, not a merge: the only consumer is the index
-- membership split in 020, where a run of unbroken index presence is
-- what tells succession from recycling. Ticker changes at succession
-- (Paramount Global PARA -> Paramount Skydance PSKY) are not caught.
CREATE TABLE IF NOT EXISTS sec_reference.cik_succession (
    old_cik      INTEGER NOT NULL,
    new_cik      INTEGER NOT NULL,
    ticker       TEXT    NOT NULL,
    handoff_date DATE    NOT NULL,
    old_last_filed  DATE,
    new_first_filed DATE,
    PRIMARY KEY (old_cik, new_cik, ticker)
);

TRUNCATE sec_reference.cik_succession;
INSERT INTO sec_reference.cik_succession
SELECT DISTINCT ON (a.cik, b.cik, a.ticker)
       a.cik, b.cik, a.ticker, b.valid_from, ca.last_filed, cb.first_filed
FROM sec_reference.company_ticker a
JOIN sec_reference.company_ticker b
  ON b.ticker = a.ticker AND b.cik <> a.cik
 AND a.is_primary AND b.is_primary
 AND b.valid_from BETWEEN a.valid_to - 45 AND a.valid_to + 120
JOIN sec_reference.company ca ON ca.cik = a.cik
JOIN sec_reference.company cb ON cb.cik = b.cik
WHERE a.valid_to IS NOT NULL
  AND cb.first_filed > ca.first_filed + 30
ORDER BY a.cik, b.cik, a.ticker, b.valid_from;

COMMENT ON TABLE sec_reference.cik_succession IS
    'Ticker handoffs between two registrants in SEC''s own file: the old '
    'CIK''s primary interval ends where the newer CIK''s begins. Evidence of '
    'a holding-company reorganisation, indistinguishable here from a '
    'recycled ticker; consumed only by the index membership split.';

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
    'crosswalk has no interval covering it (observed from 2018-12, '
    'extended to the first filing for single-ticker histories). '
    'Tickers are recycled between unrelated companies, so resolving '
    'without a date is unsafe for any historical query.';

-- The strict variant, for callers that would otherwise pass a NULL CIK
-- straight through and return a full set of empty rows. The README once
-- showed as_of_snapshot('AAPL', DATE '2015-06-30') as the headline
-- example; it returned fifteen rows and no values, because 2015 was
-- before the crosswalk floor and nothing said so. An error says so.
-- (That example resolves today through the back-extension in 3b; the
-- guard still matters for every ticker the extension cannot reach.)
CREATE OR REPLACE FUNCTION sec_reference.cik_at_strict(p_ticker TEXT, p_asof DATE)
RETURNS INTEGER
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cik INTEGER;
BEGIN
    v_cik := sec_reference.cik_at(p_ticker, p_asof);
    IF v_cik IS NULL THEN
        RAISE EXCEPTION 'No company held ticker % on %. The crosswalk is '
            'observed from 2018-12 and extended earlier only for '
            'single-ticker histories; resolve the CIK yourself and call '
            'the CIK-keyed function.',
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
