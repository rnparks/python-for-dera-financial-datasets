-- create_silver.sql (Fixed)

-- 1. CLEAN SLATE
DROP SCHEMA IF EXISTS sec_silver CASCADE;
CREATE SCHEMA sec_silver;

-- 2. SUB_SILVER (Company Metadata)
-- No changes needed here, just removed the RAISE command
CREATE TABLE sec_silver.sub_silver AS
SELECT
    adsh,
    cik::INTEGER,
    name,
    sic::INTEGER,
    countryba,
    stprba,
    cityba,
    zipba,
    bas1,
    form,
    period::DATE as period_date,
    fy::INTEGER,
    fp,
    filed::DATE as filed_date,
    accepted::TIMESTAMP as accepted_time
FROM sec_raw.sub_raw
WHERE adsh IS NOT NULL;

ALTER TABLE sec_silver.sub_silver ADD PRIMARY KEY (adsh);
CREATE INDEX idx_sub_cik ON sec_silver.sub_silver (cik);


-- 3. TAG_SILVER (Taxonomy Definitions)
-- FIX: Added DISTINCT ON to handle duplicates in the raw data
CREATE TABLE sec_silver.tag_silver AS
SELECT DISTINCT ON (tag, version)
    tag,
    version,
    custom::BOOLEAN,
    abstract::BOOLEAN,
    datatype,
    tlabel,
    doc
FROM sec_raw.tag_raw
ORDER BY tag, version; 

ALTER TABLE sec_silver.tag_silver ADD PRIMARY KEY (tag, version);


-- 4. NUM_SILVER (The Master Fact Table)
-- Removed RAISE command. Logic remains the same.
CREATE TABLE sec_silver.num_silver AS
WITH raw_typed AS (
    SELECT
        n.adsh,
        s.cik,
        n.tag,
        n.version,
        n.ddate::DATE as value_date,
        n.qtrs::INTEGER,
        n.uom,
        n.coreg,
        NULLIF(n.segments, '') as segments,
        CASE 
            WHEN n.value ~ '^[0-9\.\-]+$' THEN n.value::NUMERIC 
            ELSE NULL 
        END as value,
        n.footnote,
        s.filed_date,
        s.form
    FROM sec_raw.num_raw n
    JOIN sec_silver.sub_silver s ON n.adsh = s.adsh
)
SELECT
    r.adsh,
    r.cik,
    r.tag,
    r.version,
    t.tlabel,
    r.value_date,
    r.qtrs,
    r.uom,
    r.coreg,
    r.segments,
    r.value,
    r.footnote,
    r.filed_date,
    r.form,
    -- POINT IN TIME RANKING
    ROW_NUMBER() OVER (
        PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
        ORDER BY r.filed_date DESC, r.adsh DESC
    ) as point_in_time_rank
FROM raw_typed r
LEFT JOIN sec_silver.tag_silver t 
    ON r.tag = t.tag AND r.version = t.version;

-- 5. INDEXING
CREATE INDEX idx_num_cik_tag ON sec_silver.num_silver (cik, tag);
CREATE INDEX idx_num_rank ON sec_silver.num_silver (point_in_time_rank) WHERE point_in_time_rank = 1;


-- 6. GOLD VIEW
CREATE OR REPLACE VIEW sec_silver.view_financials_consolidated AS
SELECT 
    cik,
    tlabel as metric,
    tag,
    value_date,
    qtrs,
    value,
    filed_date
FROM sec_silver.num_silver
WHERE point_in_time_rank = 1
  AND segments IS NULL
  AND coreg IS NULL;