-- init_sec.sql

-- 1. CLEANUP
DROP PROCEDURE IF EXISTS sec_raw.load_sec_data(text) CASCADE;
DROP TABLE IF EXISTS sec_raw.num_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.sub_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.tag_raw CASCADE;
DROP TABLE IF EXISTS sec_raw.pre_raw CASCADE;

-- 2. SCHEMA & TABLES
CREATE SCHEMA IF NOT EXISTS sec_raw;

CREATE TABLE sec_raw.sub_raw (
    adsh TEXT, cik TEXT, name TEXT, sic TEXT, countryba TEXT, stprba TEXT, 
    cityba TEXT, zipba TEXT, bas1 TEXT, bas2 TEXT, baph TEXT, countryma TEXT, 
    stprma TEXT, cityma TEXT, zipma TEXT, mas1 TEXT, mas2 TEXT, maph TEXT, 
    countryinc TEXT, stprinc TEXT, ein TEXT, former TEXT, changed TEXT, 
    afs TEXT, wksi TEXT, fye TEXT, form TEXT, period TEXT, fy TEXT, fp TEXT, 
    filed TEXT, accepted TEXT, prevproc TEXT, prevrpt TEXT, acks TEXT, 
    noj TEXT, act TEXT, file TEXT, film TEXT, wc TEXT, detail TEXT, 
    instance TEXT, nciks TEXT, aciks TEXT
);

CREATE TABLE sec_raw.tag_raw (
    tag TEXT, version TEXT, custom TEXT, abstract TEXT, datatype TEXT, 
    iord TEXT, crdr TEXT, tlabel TEXT, doc TEXT
);

CREATE TABLE sec_raw.num_raw (
    adsh TEXT, tag TEXT, version TEXT, coreg TEXT, ddate TEXT, qtrs TEXT, 
    uom TEXT, value TEXT, footnote TEXT, segments TEXT, dimh TEXT, 
    iprx TEXT, durp TEXT, datp TEXT, dcml TEXT, txt TEXT
);

CREATE TABLE sec_raw.pre_raw (
    adsh TEXT, report TEXT, line TEXT, stmt TEXT, inpth TEXT, rfile TEXT, 
    tag TEXT, version TEXT, plabel TEXT, negating TEXT
);

-- 3. PROCEDURE (The "Cut" Method)
CREATE OR REPLACE PROCEDURE sec_raw.load_sec_data(base_dir TEXT)
LANGUAGE plpgsql
AS $$
DECLARE 
    f record;
    cmd_find TEXT;
    cmd_head TEXT;
    file_header TEXT;
    table_name TEXT;
    copy_cmd TEXT;
    col_list TEXT;
    col_count INT;
    program_cmd TEXT;
BEGIN
    -- Setup Temp Tables
    CREATE TEMP TABLE IF NOT EXISTS found_files (filepath text) ON COMMIT DROP;
    CREATE TEMP TABLE IF NOT EXISTS header_capture (line text) ON COMMIT DROP;

    -- Find all .txt files
    cmd_find := format('find %s -type f -name "*.txt"', base_dir);
    EXECUTE format('COPY found_files FROM PROGRAM %L', cmd_find);

    RAISE NOTICE 'Found files. Starting ingestion...';

    FOR f IN SELECT filepath FROM found_files ORDER BY filepath LOOP
        
        -- Identify target table
        IF f.filepath ~ '/sub\.txt$' THEN table_name := 'sec_raw.sub_raw';
        ELSIF f.filepath ~ '/tag\.txt$' THEN table_name := 'sec_raw.tag_raw';
        ELSIF f.filepath ~ '/num\.txt$' THEN table_name := 'sec_raw.num_raw';
        ELSIF f.filepath ~ '/pre\.txt$' THEN table_name := 'sec_raw.pre_raw';
        ELSE CONTINUE; 
        END IF;

        -- Read the header
        TRUNCATE header_capture;
        cmd_head := format('head -n 1 %s', f.filepath);
        EXECUTE format('COPY header_capture FROM PROGRAM %L WITH (FORMAT text, DELIMITER E''\x01'')', cmd_head);
        
        SELECT line INTO file_header FROM header_capture LIMIT 1;
        IF file_header IS NULL THEN CONTINUE; END IF;

        -- Sanitize header
        col_list := replace(lower(file_header), E'\t', ',');
        
        -- CALCULATE COLUMN COUNT
        -- We split the header by comma and count the items.
        col_count := array_length(string_to_array(col_list, ','), 1);

        -- Execute COPY using 'cut'
        BEGIN
            -- 1. Construct the Shell Command
            -- "cat file | tr -d '\r' | cut -f 1-N"
            -- This explicitly limits the output to N columns, dropping any trailing garbage.
            program_cmd := format('cat %L | tr -d ''\r'' | cut -f 1-%s', f.filepath, col_count);

            -- 2. Construct the SQL Command
            -- We use %L for program_cmd to handle the quoting automatically.
            copy_cmd := format(
                'COPY %s (%s) FROM PROGRAM %L WITH (FORMAT CSV, DELIMITER E''\t'', HEADER, ENCODING ''LATIN1'', QUOTE E''\x01'')',
                table_name, col_list, program_cmd
            );
            
            EXECUTE copy_cmd;
        
        EXCEPTION WHEN OTHERS THEN
            RAISE WARNING 'FAILED to load %: %', f.filepath, SQLERRM;
        END;

    END LOOP;

    RAISE NOTICE 'Ingestion Complete.';
END $$;