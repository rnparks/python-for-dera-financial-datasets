-- ==========================================
-- SEC Financial Statement Data Sets Loader
-- Ground-up, stable implementation
-- ==========================================

-- ==========================================
-- 1. CLEANUP
-- ==========================================
DROP PROCEDURE IF EXISTS sec_raw.load_sec_data(text) CASCADE;

DROP TABLE IF EXISTS sec_raw.sub_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.tag_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.num_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.pre_raw CASCADE;

DROP SCHEMA IF EXISTS sec_raw CASCADE;

-- ==========================================
-- 2. SCHEMA
-- ==========================================
CREATE SCHEMA sec_raw;

-- ==========================================
-- 3. TABLES (SEC-DEFINED ORDER)
-- ==========================================

CREATE TABLE sec_raw.sub_raw (
    adsh TEXT,
    cik TEXT,
    name TEXT,
    sic TEXT,
    countryba TEXT,
    stprba TEXT,
    cityba TEXT,
    zipba TEXT,
    bas1 TEXT,
    bas2 TEXT,
    baph TEXT,
    countryma TEXT,
    stprma TEXT,
    cityma TEXT,
    zipma TEXT,
    mas1 TEXT,
    mas2 TEXT,
    maph TEXT,
    countryinc TEXT,
    stprinc TEXT,
    ein TEXT,
    former TEXT,
    changed TEXT,
    afs TEXT,
    wksi TEXT,
    fye TEXT,
    form TEXT,
    period TEXT,
    fy TEXT,
    fp TEXT,
    filed TEXT,
    accepted TEXT,
    prevproc TEXT,
    prevrpt TEXT,
    acks TEXT,
    noj TEXT,
    act TEXT,
    file TEXT,
    film TEXT,
    wc TEXT,
    detail TEXT,
    instance TEXT,
    nciks TEXT,
    aciks TEXT
);

CREATE TABLE sec_raw.tag_raw (
    tag TEXT,
    version TEXT,
    custom TEXT,
    abstract TEXT,
    datatype TEXT,
    iord TEXT,
    crdr TEXT,
    tlabel TEXT,
    doc TEXT
);

CREATE TABLE sec_raw.num_raw (
    adsh TEXT,
    tag TEXT,
    version TEXT,
    coreg TEXT,
    ddate TEXT,
    qtrs TEXT,
    uom TEXT,
    segments TEXT,
    value TEXT,
    footnote TEXT
);

CREATE TABLE sec_raw.pre_raw (
    adsh TEXT,
    report TEXT,
    line TEXT,
    stmt TEXT,
    inpth TEXT,
    rfile TEXT,
    tag TEXT,
    version TEXT,
    plabel TEXT,
    negating TEXT
);

-- ==========================================
-- 4. LOADER PROCEDURE
-- ==========================================
CREATE OR REPLACE PROCEDURE sec_raw.load_sec_data(base_dir TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    f RECORD;
    tbl TEXT;
BEGIN
    CREATE TEMP TABLE files (path TEXT) ON COMMIT DROP;

    EXECUTE format(
        'COPY files FROM PROGRAM %L',
        'find ' || base_dir || ' -type f -name "*.txt"'
    );

    RAISE NOTICE 'Found files. Starting ingestion...';

    FOR f IN SELECT path FROM files ORDER BY path LOOP

        IF f.path ~ '/sub\.txt$' THEN
            tbl := 'sec_raw.sub_raw';
        ELSIF f.path ~ '/tag\.txt$' THEN
            tbl := 'sec_raw.tag_raw';
        ELSIF f.path ~ '/num\.txt$' THEN
            tbl := 'sec_raw.num_raw';
        ELSIF f.path ~ '/pre\.txt$' THEN
            tbl := 'sec_raw.pre_raw';
        ELSE
            CONTINUE;
        END IF;

        BEGIN
            EXECUTE format(
                'COPY %s FROM %L WITH (
                    FORMAT CSV,
                    HEADER TRUE,
                    DELIMITER E''\t'',
                    NULL '''',
                    ENCODING ''LATIN1''
                )',
                tbl,
                f.path
            );
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'FAILED %: %', f.path, SQLERRM;
        END;

    END LOOP;

    RAISE NOTICE 'Ingestion complete.';
END;
$$;
