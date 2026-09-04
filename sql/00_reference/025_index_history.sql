-- Raw index-constituent observations, replayed from Wikipedia revisions.
--
-- Same evidence discipline as ticker_observation: one row per (index,
-- capture, ticker) exactly as the page gave it on that date, never
-- interpreted here. The intervals are derived in
-- sql/05_spine/020_index_membership.sql, where the capture-quality and
-- bridging rules live, and the universe rows in
-- sql/06_security/030_index_universe.sql.
--
-- Lives in sec_reference so a silver rebuild does not take it out, and
-- is loaded by reference.load_calendar_only() from
-- data/reference/sp500_history.csv.gz (tools/fetch_sp500_history.py).
--
-- GICS is recorded per capture because the page carried it on every
-- revision -- which makes sector and sub-industry AS OF for the first
-- time; the current-snapshot universe never had a date on either.
-- The CIK column exists on the page from 2014; earlier captures carry
-- the ticker and name only, and cik is NULL until resolved downstream.

CREATE SCHEMA IF NOT EXISTS sec_reference;

CREATE TABLE IF NOT EXISTS sec_reference.index_observation (
    index_name         TEXT    NOT NULL,
    observed_on        DATE    NOT NULL,
    revid              BIGINT  NOT NULL,
    ticker             TEXT    NOT NULL,
    name               TEXT,
    cik                INTEGER,
    gics_sector        TEXT,
    gics_sub_industry  TEXT,
    date_added         DATE,
    PRIMARY KEY (index_name, observed_on, ticker)
);

CREATE INDEX IF NOT EXISTS idx_indexobs_ticker ON sec_reference.index_observation (index_name, ticker);
CREATE INDEX IF NOT EXISTS idx_indexobs_cik    ON sec_reference.index_observation (cik) WHERE cik IS NOT NULL;

COMMENT ON TABLE sec_reference.index_observation IS
    'One row per (index, Wikipedia revision capture, ticker) as the '
    'constituents table showed it that day. Evidence, not '
    'interpretation; cik is NULL where the page had none (before 2014).';
