-- 1. Reset the table (just in case)
DROP TABLE IF EXISTS sec_silver.ticker_map CASCADE;

CREATE TABLE sec_silver.ticker_map (
    ticker TEXT PRIMARY KEY,
    cik INTEGER NOT NULL,
    name TEXT,
    exchange TEXT
);

CREATE INDEX idx_map_cik ON sec_silver.ticker_map(cik);

-- 2. LOAD with Explicit Column Mapping
-- We tell Postgres: "The first column in the file is CIK, the second is Ticker..."
\copy sec_silver.ticker_map(cik, ticker, name, exchange) FROM 'tickers.csv' WITH (FORMAT CSV);