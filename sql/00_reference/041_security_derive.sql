-- Derive the security model from raw EDGAR filing events.
--
-- Raw events land in staging from data/reference/security_events.csv; all
-- interpretation happens here, in SQL, so the rules are auditable and the
-- evidence stays separable from the conclusion -- the same split
-- fetch_ticker_history.py uses.
--
-- THE DELISTING RULE, AND WHY IT IS NOT "A FORM 25 MEANS DELISTED".
--
-- That naive rule is wrong by a wide margin, and it was measured rather
-- than reasoned about. Across an 18-company slice:
--
--   JPMorgan   46 Form 25 notices, never delisted. They retire preferred
--              series and structured notes continuously.
--   Apple       5 notices, never delisted.
--   Palantir    a Form 25 AND an 8-A12B on the SAME DAY (2024-11-25),
--              which is the NYSE -> Nasdaq transfer, not a delisting.
--   SVB         a 2017 notice followed by a new 8-A12B in 2019 and four
--              more years of filings, then the real one in 2023.
--
-- A Form 25 is filed per CLASS of security. The company-level signal is
-- behavioural: the notice ends the company only if nothing re-registers
-- and the periodic reports stop.
--
--   1. No LISTING_REGISTRATION on or after the notice date.
--      On, not merely after -- the same-day pair is the transfer case,
--      and a strict inequality silently delisted a live company.
--   2. No periodic report more than GRACE days after the notice.
--
-- RECENCY. A notice inside the grace window cannot yet have the evidence
-- that would clear it, because not enough time has passed for a following
-- report to exist. Those are marked is_provisional rather than asserted.

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
