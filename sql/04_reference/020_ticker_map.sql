-- CIK ↔ ticker crosswalk. LEGACY AND SURVIVORSHIP-BIASED.
--
-- This is SEC's current-state file: it lists only companies registered
-- with a ticker today. Every company that delisted, was acquired or went
-- bankrupt has been deleted from it, so it is missing 58.5% of 2013
-- filers and 36.1% of 2019 filers. It cannot be used to reconstruct a
-- historical universe.
--
-- `sec_reference.company_ticker` supersedes it: dated validity intervals
-- built from archived snapshots, keeping companies that no longer exist.
-- New work joins that. This table is retained only because three gold
-- helper functions still resolve tickers through it
-- (040_helper_functions, 060_canonical_function, 070_fiscal_year_views).
--
-- Populated by dera_pipeline.reference from data/reference/tickers.csv.
-- The legacy \copy statement loaded (cik, ticker, name, exchange) column
-- order from that file; the column order is preserved.
DROP TABLE IF EXISTS sec_silver.ticker_map CASCADE;

CREATE TABLE sec_silver.ticker_map (
    ticker   TEXT PRIMARY KEY,
    cik      INTEGER NOT NULL,
    name     TEXT,
    exchange TEXT
);

CREATE INDEX idx_ticker_map_cik ON sec_silver.ticker_map (cik);
