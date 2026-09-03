-- Survivorship-free CIK to ticker crosswalk.
--
-- Two tables, deliberately separated:
--
--   ticker_observation -- raw evidence. One row per (cik, ticker) seen
--                         in one dated snapshot of SEC's
--                         company_tickers.json. Append-only facts, never
--                         interpreted. Keeping these means the interval
--                         logic below can be re-derived or corrected
--                         without re-downloading anything.
--
--   company_ticker     -- validity intervals derived from those
--                         observations. This is what queries join to.
--
-- Why this exists: SEC's live file lists only currently-registered
-- companies, so it silently deletes anything that delisted, was acquired
-- or went bankrupt. Against companies that actually filed a 10-K it is
-- missing 58.5% of 2013 filers and 36.1% of 2019 filers. Joining a
-- historical universe through the live file drops those companies
-- without warning, which is textbook survivorship bias.
--
-- Populated from data/reference/ticker_history.csv, built by
-- `uv run python tools/fetch_ticker_history.py`.

CREATE SCHEMA IF NOT EXISTS sec_reference;

CREATE TABLE IF NOT EXISTS sec_reference.ticker_observation (
    cik          INTEGER NOT NULL,
    ticker       TEXT    NOT NULL,
    title        TEXT,
    observed_on  DATE    NOT NULL,
    source       TEXT    NOT NULL,
    PRIMARY KEY (cik, ticker, observed_on)
);

CREATE INDEX IF NOT EXISTS idx_tickobs_cik
    ON sec_reference.ticker_observation (cik);
CREATE INDEX IF NOT EXISTS idx_tickobs_ticker
    ON sec_reference.ticker_observation (ticker);

COMMENT ON TABLE sec_reference.ticker_observation IS
    'Raw dated sightings of a CIK/ticker pair in a snapshot of SEC '
    'company_tickers.json. Evidence, not interpretation.';
COMMENT ON COLUMN sec_reference.ticker_observation.observed_on IS
    'Date of the snapshot this pair was seen in. NOT the date the '
    'ticker was assigned - we only know the company held it on this day.';
