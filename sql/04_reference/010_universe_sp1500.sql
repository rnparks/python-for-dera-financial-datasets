-- S&P 1500 universe (S&P 500 + 400 + 600). One row per unique ticker.
-- Populated by dera_pipeline.reference from data/reference/sp1500_universe.csv.
-- gics_sector and gics_sub_industry are sourced from Wikipedia's S&P index
-- pages, which expose the official S&P/MSCI GICS classification for each
-- constituent. Older pre-GICS rows or tickers from pages that lack the
-- column are loaded with NULL.
DROP TABLE IF EXISTS sec_silver.universe_sp1500 CASCADE;

CREATE TABLE sec_silver.universe_sp1500 (
    ticker            TEXT PRIMARY KEY,
    name              TEXT,
    index_name        TEXT,
    gics_sector       TEXT,
    gics_sub_industry TEXT
);

CREATE INDEX idx_sp1500_sector       ON sec_silver.universe_sp1500 (gics_sector);
CREATE INDEX idx_sp1500_sub_industry ON sec_silver.universe_sp1500 (gics_sub_industry);
