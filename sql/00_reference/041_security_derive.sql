-- Staging tables for raw EDGAR filing events.
--
-- DDL ONLY. This file creates the two staging tables and their indexes and
-- interprets nothing. The rules that turn these events into securities,
-- listings and delistings -- including the delisting discriminator and its
-- going-concern gate -- live in sql/06_security/010_security_populate.sql,
-- which must run AFTER the loader has filled these tables.
--
-- Events are streamed in by dera_pipeline.filings.load_security_events()
-- via COPY FROM STDIN out of data/edgar/submissions.zip: 910,661 events
-- across 17,015 CIKs as of 2026-09-04. Keeping the raw evidence separate
-- from its interpretation is the same split fetch_ticker_history.py uses.

DROP TABLE IF EXISTS sec_reference.security_event_raw CASCADE;
CREATE TABLE sec_reference.security_event_raw (
    cik        INTEGER,
    event_type TEXT,
    event_date DATE,
    form       TEXT,
    adsh       TEXT
);

DROP TABLE IF EXISTS sec_reference.company_name_raw CASCADE;
CREATE TABLE sec_reference.company_name_raw (
    cik        INTEGER,
    name       TEXT,
    valid_from TEXT,
    valid_to   TEXT
);

-- Indexes on staging. At slice scale (1,815 rows) these were irrelevant;
-- at full scale the event table holds millions of rows and the delisting
-- rule runs two correlated NOT EXISTS per notice, so without them the
-- derivation degrades to a quadratic scan.
CREATE INDEX idx_sev_cik_type_date
    ON sec_reference.security_event_raw (cik, event_type, event_date);
CREATE INDEX idx_cnr_cik ON sec_reference.company_name_raw (cik);
