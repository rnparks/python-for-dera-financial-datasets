-- Index CIK overrides: the allowlist behind the membership resolution.
--
-- A constituent run -- one ticker present in consecutive captures of
-- one index -- resolves to a CIK from the page, SEC's dated crosswalk
-- or a dated name match (sql/05_spine/020_index_membership.sql,
-- section 2). A run none of those can settle is listed in
-- index_membership_unresolved, never guessed. This table is the next
-- source: a row names one run by (index, ticker, first sighting) and
-- the CIK the evidence supports, with the evidence written down. It
-- fills a run nothing else resolves and never overrides one that is;
-- check 61 fails on a row that has become redundant or names a CIK
-- that never filed.
--
-- Loaded by reference.load_index_cik_overrides() from
-- data/reference/index_cik_overrides.csv. The loader runs this file
-- first, so an existing database gains the table on its next
-- `dera rebuild-reference`; a full build creates it here.

CREATE SCHEMA IF NOT EXISTS sec_reference;

CREATE TABLE IF NOT EXISTS sec_reference.index_cik_override (
    index_name  TEXT    NOT NULL CHECK (index_name IN ('SP500', 'SP400', 'SP600')),
    ticker      TEXT    NOT NULL CHECK (ticker <> ''),
    first_seen  DATE    NOT NULL,
    cik         INTEGER NOT NULL CHECK (cik > 0),
    source_note TEXT    NOT NULL CHECK (source_note <> ''),
    PRIMARY KEY (index_name, ticker, first_seen)
);

COMMENT ON TABLE sec_reference.index_cik_override IS
    'Hand-resolved constituent runs: (index, ticker, first sighting) -> CIK, '
    'each row citing its evidence. Applied only where the page, the crosswalk '
    'and the name all failed; a redundant row fails check 61.';
