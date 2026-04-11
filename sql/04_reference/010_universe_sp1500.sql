-- S&P 1500 universe (S&P 500 + 400 + 600). One row per unique ticker.
-- Populated by dera_pipeline.reference from data/reference/sp1500_universe.csv.
DROP TABLE IF EXISTS sec_silver.universe_sp1500 CASCADE;

CREATE TABLE sec_silver.universe_sp1500 (
    ticker     TEXT PRIMARY KEY,
    name       TEXT,
    index_name TEXT
);
