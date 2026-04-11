-- Company metadata: one row per filing.
CREATE TABLE sec_silver.sub_silver AS
SELECT
    adsh,
    cik::INTEGER                  AS cik,
    name,
    sic::INTEGER                  AS sic,
    countryba,
    stprba,
    cityba,
    zipba,
    bas1,
    form,
    period::DATE                  AS period_date,
    fy::INTEGER                   AS fy,
    fp,
    filed::DATE                   AS filed_date,
    accepted::TIMESTAMP           AS accepted_time
FROM sec_raw.sub_raw
WHERE adsh IS NOT NULL;

ALTER TABLE sec_silver.sub_silver ADD PRIMARY KEY (adsh);
CREATE INDEX idx_sub_cik ON sec_silver.sub_silver (cik);
