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
    aciks TEXT
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
    doc TEXT
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
    footnote TEXT
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
    negating TEXT
);
