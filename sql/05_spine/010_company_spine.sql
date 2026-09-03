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
-- 2. Dated ticker intervals derived from the raw observations.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.company_ticker CASCADE;

CREATE TABLE sec_reference.company_ticker AS
WITH snap AS (
    -- Dense sequence over the distinct snapshot dates, so "was it
    -- present in consecutive snapshots" becomes integer arithmetic.
    SELECT observed_on,
           ROW_NUMBER() OVER (ORDER BY observed_on) AS sn
    FROM (SELECT DISTINCT observed_on FROM sec_reference.ticker_observation) d
),
runs AS (
    -- Classic gaps-and-islands: subtracting a per-pair row number from
    -- the global snapshot number gives a constant per unbroken run, so
    -- a ticker that lapses and is later reissued yields two intervals
    -- rather than one falsely continuous one.
    SELECT o.cik, o.ticker, o.observed_on, s.sn,
           s.sn - ROW_NUMBER() OVER (PARTITION BY o.cik, o.ticker ORDER BY s.sn)
               AS run_key
    FROM sec_reference.ticker_observation o
    JOIN snap s USING (observed_on)
),
collapsed AS (
    SELECT cik, ticker,
           MIN(observed_on) AS valid_from,
           MAX(sn)          AS last_sn
    FROM runs
    GROUP BY cik, ticker, run_key
),
intervals AS (
    SELECT
        c.cik,
        c.ticker,
        c.valid_from,
        -- The first snapshot in which the pair was absent. That is the
        -- earliest date we can prove it was gone. NULL means it was
        -- still present in the most recent snapshot.
        nxt.observed_on AS valid_to
    FROM collapsed c
    LEFT JOIN snap nxt ON nxt.sn = c.last_sn + 1
),
-- A CIK can hold several tickers at once: share classes (GOOG and
-- GOOGL), preferred lines, exchange-traded debt. 26,724 pairs of
-- intervals overlap this way. Joining facts to this table on cik alone
-- would therefore multiply rows -- every Alphabet figure counted twice.
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
    'First snapshot date the pair was absent, i.e. the earliest date we '
    'can prove the ticker was gone. NULL means still current. The true '
    'end date lies between the prior snapshot and this one.';

-- ---------------------------------------------------------------
-- 3. Convenience view: the ticker to show for a CIK today.
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
-- 4. As-of resolvers. Both return at most one row, so they can be
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
    'Which company held this ticker on this date. Tickers are recycled '
    'between unrelated companies, so resolving without a date is unsafe '
    'for any historical query.';
