-- import_sp1500.sql

-- 1. Setup the Final Table
DROP TABLE IF EXISTS sec_silver.universe_sp1500;
CREATE TABLE sec_silver.universe_sp1500 (
    ticker TEXT PRIMARY KEY,
    name TEXT,
    index_name TEXT
);

-- 2. Setup a Temporary Staging Table (No Primary Key, so it accepts duplicates)
DROP TABLE IF EXISTS tmp_sp1500_stage;
CREATE TEMP TABLE tmp_sp1500_stage (
    ticker TEXT,
    name TEXT,
    index_name TEXT
);

-- 3. Load the CSV into the Staging Table
\copy tmp_sp1500_stage (ticker, name, index_name) FROM 'sp1500_universe.csv' WITH (FORMAT CSV, HEADER);

-- 4. Clean & Move to Final Table
-- We use DISTINCT ON (ticker) to ensure we only keep ONE entry per ticker.
INSERT INTO sec_silver.universe_sp1500 (ticker, name, index_name)
SELECT DISTINCT ON (ticker) 
    REPLACE(ticker, '.', '-') as ticker, -- Fix the dot/hyphen issue here
    name, 
    index_name
FROM tmp_sp1500_stage
ORDER BY ticker, index_name;

-- 5. Cleanup
DROP TABLE tmp_sp1500_stage;

-- 6. Verify
SELECT index_name, COUNT(*) as count 
FROM sec_silver.universe_sp1500 
GROUP BY index_name 
ORDER BY count DESC;