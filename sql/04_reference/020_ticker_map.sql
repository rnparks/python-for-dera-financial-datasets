-- CIK ↔ ticker crosswalk. Populated by dera_pipeline.reference from
-- data/reference/tickers.csv. The legacy \copy statement loaded
-- (cik, ticker, name, exchange) column order from tickers.csv; that
-- column order is preserved.
DROP TABLE IF EXISTS sec_silver.ticker_map CASCADE;

CREATE TABLE sec_silver.ticker_map (
    ticker   TEXT PRIMARY KEY,
    cik      INTEGER NOT NULL,
    name     TEXT,
    exchange TEXT
);

CREATE INDEX idx_ticker_map_cik ON sec_silver.ticker_map (cik);
