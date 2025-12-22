-- create_tradable_view.sql (Fixed)

-- 1. Clean up
DROP MATERIALIZED VIEW IF EXISTS sec_silver.tradable_financials CASCADE;

-- 2. Create the High-Performance View (Consolidated Only)
CREATE MATERIALIZED VIEW sec_silver.tradable_financials AS
SELECT 
    -- Context
    u.ticker,
    u.name as company_name,
    u.index_name, 
    
    -- Financials
    n.cik,
    n.tag,
    n.tlabel as metric,
    n.value_date,
    n.filed_date,
    n.qtrs,
    n.value,
    
    -- Ranks
    n.rank_pit,
    n.rank_latest

FROM sec_silver.universe_sp1500 u
JOIN sec_silver.ticker_map m 
    ON u.ticker = m.ticker
JOIN sec_silver.num_silver n 
    ON m.cik = n.cik
WHERE n.segments IS NULL   -- <--- CRITICAL FIX: Exclude breakdown/segment data
  AND n.coreg IS NULL;     -- <--- CRITICAL FIX: Exclude subsidiary data

-- 3. Indexing
CREATE INDEX idx_tradable_ticker ON sec_silver.tradable_financials(ticker);
CREATE INDEX idx_tradable_date   ON sec_silver.tradable_financials(value_date);
CREATE INDEX idx_tradable_tag    ON sec_silver.tradable_financials(tag);
CREATE INDEX idx_tradable_pit    ON sec_silver.tradable_financials(rank_pit);

-- 4. Verify
SELECT count(*) as "Clean Rows" FROM sec_silver.tradable_financials;