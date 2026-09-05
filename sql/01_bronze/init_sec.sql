-- Bronze layer: raw SEC DERA Financial Statement Data Sets.
--
-- Column order matches the actual .txt files published by SEC (verified
-- against examples/data/2025q3/{sub,tag,num,pre}.txt). The legacy init
-- scripts put `coreg` at num_raw position 4 and added 6 phantom columns
-- (dimh, iprx, durp, datp, dcml, txt) that belong to the SEC Notes
-- dataset, not the Financial Statement Data Sets — those are gone.
-- sub_raw likewise drops 8 phantom columns (maph, prevproc, acks, noj,
-- act, file, film, wc) that never appear in real sub.txt.
--
-- Bronze is loaded by dera_pipeline.loader, not by a plpgsql procedure.
--
-- Every table carries `source_quarter`, the DERA file the row came from
-- (e.g. '2026q2'). COPY cannot set a constant, so the column takes its
-- DEFAULT from a transaction-local setting the loader makes before each
-- COPY -- one pass over the file, no staging table -- and loading with
-- the setting absent fails outright rather than writing NULLs. It is
-- what lets one quarter be replaced (`dera load --quarter Q --force`)
-- and what the incremental silver build reads. Bronze had no such
-- column until 2026-09-04, when a second COPY of a quarter could only
-- double its rows and the only way back was a full reload.

DROP SCHEMA IF EXISTS sec_raw CASCADE;
CREATE SCHEMA sec_raw;

-- sub.txt — 36 columns
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
    prevrpt TEXT,
    detail TEXT,
    instance TEXT,
    nciks TEXT,
    aciks TEXT,
    source_quarter TEXT NOT NULL DEFAULT current_setting('dera.load_quarter')
);

-- tag.txt — 9 columns
CREATE TABLE sec_raw.tag_raw (
    tag TEXT,
    version TEXT,
    custom TEXT,
    abstract TEXT,
    datatype TEXT,
    iord TEXT,
    crdr TEXT,
    tlabel TEXT,
    doc TEXT,
    source_quarter TEXT NOT NULL DEFAULT current_setting('dera.load_quarter')
);

-- num.txt — 10 columns (coreg is position 8, not position 4)
CREATE TABLE sec_raw.num_raw (
    adsh TEXT,
    tag TEXT,
    version TEXT,
    ddate TEXT,
    qtrs TEXT,
    uom TEXT,
    segments TEXT,
    coreg TEXT,
    value TEXT,
    footnote TEXT,
    source_quarter TEXT NOT NULL DEFAULT current_setting('dera.load_quarter')
);

-- pre.txt — 10 columns
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
    negating TEXT,
    source_quarter TEXT NOT NULL DEFAULT current_setting('dera.load_quarter')
);

-- Replacing one quarter, and the incremental silver build, walk these
-- tables by source_quarter. Rows are appended a quarter at a time, so
-- each quarter is physically contiguous and a BRIN index -- a few
-- hundred kilobytes on the 30 GB num_raw against ~4 GB for a btree --
-- prunes nearly every block. It costs nothing measurable at COPY time.
CREATE INDEX idx_sub_raw_quarter ON sec_raw.sub_raw USING brin (source_quarter);
CREATE INDEX idx_tag_raw_quarter ON sec_raw.tag_raw USING brin (source_quarter);
CREATE INDEX idx_num_raw_quarter ON sec_raw.num_raw USING brin (source_quarter);
CREATE INDEX idx_pre_raw_quarter ON sec_raw.pre_raw USING brin (source_quarter);
