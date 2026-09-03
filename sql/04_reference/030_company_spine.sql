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
-- Runs after 02_silver because the spine reads `sub_silver`.

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
)
SELECT
    c.cik,
    c.ticker,
    c.valid_from,
    -- The first snapshot in which the pair was absent. That is the
    -- earliest date we can prove it was gone. NULL means it was still
    -- present in the most recent snapshot.
    nxt.observed_on AS valid_to
FROM collapsed c
LEFT JOIN snap nxt ON nxt.sn = c.last_sn + 1;

ALTER TABLE sec_reference.company_ticker
    ADD PRIMARY KEY (cik, ticker, valid_from);
CREATE INDEX idx_compticker_cik    ON sec_reference.company_ticker (cik);
CREATE INDEX idx_compticker_ticker ON sec_reference.company_ticker (ticker);
CREATE INDEX idx_compticker_range  ON sec_reference.company_ticker (valid_from, valid_to);

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
      ORDER BY ct.valid_to IS NULL DESC, ct.valid_from DESC
      LIMIT 1)                                   AS ticker_latest,
    EXISTS (SELECT 1 FROM sec_reference.company_ticker ct
             WHERE ct.cik = co.cik AND ct.valid_to IS NULL) AS ticker_is_current
FROM sec_reference.company co;

COMMENT ON VIEW sec_reference.company_label IS
    'Human-readable label for a CIK. ticker_latest is for display only; '
    'use company_ticker with a date for any as-of join.';
