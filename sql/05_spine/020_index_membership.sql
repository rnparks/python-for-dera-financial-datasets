-- Dated index membership derived from the constituent captures.
--
-- Three steps, mirroring the ticker crosswalk exactly, because the
-- evidence has the same shape and the same failure modes:
--
--   1. index_capture       -- every capture with its size and a partial
--                             flag (under 85% of the largest capture
--                             within six either side).
--   2. CIK resolution      -- the page carries a CIK only from 2014.
--                             Earlier rows are resolved by CONTINUITY:
--                             a ticker present in every capture from the
--                             row's date up to the first capture where
--                             the page gave it a CIK is the same company,
--                             because a recycled ticker shows a removal
--                             and a later re-addition, not an unbroken
--                             run. Rows that cannot be resolved that way
--                             are kept in index_membership_unresolved,
--                             counted, and never guessed.
--   3. index_membership    -- intervals per (cik, index, sector,
--                             sub-industry), islands bridged across a
--                             silence when the pair is seen again within
--                             200 days or every capture in the silence
--                             is partial. A GICS reclassification ends
--                             one interval and starts the next, so the
--                             classification is as of the fact date.
--
-- The S&P 400 and 600 have no replayable history yet (their pages carry
-- a CIK column from 2019 and never, respectively), so their membership
-- is today's snapshot as a single interval from 1900-01-01 with source
-- 'current_snapshot'. That is exactly the survivorship-biased state
-- gold was in for every index before this file; it is now confined to
-- two indexes and labelled, and disappears per index as history is
-- replayed.
--
-- Runs after 010_company_spine.sql (it reads company_ticker to check
-- that a resolved CIK really held the ticker) and before 06_security.

-- ---------------------------------------------------------------
-- 1. Capture quality.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.index_capture CASCADE;

CREATE TABLE sec_reference.index_capture AS
SELECT index_name, observed_on, revid,
       ROW_NUMBER() OVER (PARTITION BY index_name ORDER BY observed_on)::INTEGER AS sn,
       n_rows, window_max,
       n_rows < 0.85 * window_max AS is_partial
FROM (
    SELECT index_name, observed_on, revid, n_rows,
           MAX(n_rows) OVER (PARTITION BY index_name ORDER BY observed_on
                             ROWS BETWEEN 6 PRECEDING AND 6 FOLLOWING) AS window_max
    FROM (SELECT index_name, observed_on, MIN(revid) AS revid, COUNT(*) AS n_rows
          FROM sec_reference.index_observation GROUP BY 1, 2) c
) s;

ALTER TABLE sec_reference.index_capture ADD PRIMARY KEY (index_name, observed_on);
CREATE UNIQUE INDEX idx_index_capture_sn ON sec_reference.index_capture (index_name, sn);

-- ---------------------------------------------------------------
-- 2. CIK resolution: the page, then continuity, then the name.
-- ---------------------------------------------------------------
-- A run of presence that ended before the page carried CIKs (all
-- before April 2014) gets a third chance by NAME: the constituent's
-- name as the page wrote it, normalised, must equal exactly one
-- company's name in the spine -- any name the company has ever filed
-- under -- and that company must have been filing around the dates the
-- ticker was listed. One match resolves; zero or several stay
-- unresolved and are listed, never guessed. Measured 2026-09-04: 110 of
-- 157 such runs resolve this way; most of the rest left the index
-- before DERA coverage begins and have no facts to join to anyway.
CREATE OR REPLACE FUNCTION sec_reference.norm_company_name(t TEXT) RETURNS TEXT
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT regexp_replace(
             regexp_replace(
               regexp_replace(lower(coalesce(t, '')),
                 -- state-of-incorporation and edition suffixes the spine
                 -- uses: "CLOROX CO /DE/", "Transocean Inc. (New)"
                 '/[a-z]{2,3}/|\(new\)|\mnew\M$', ' ', 'g'),
               -- share-class tails and corporate-form words on either side
               '\m(cl\.? ?[ab]|class ?[ab]|the|inc|incorporated|corp|corporation|co|cos|company|companies|ltd|limited|plc|holdings?|hldgs?|group|grp|llc|lp|l\.p|sa|nv|ag|international|intl|int''l)\M|-[ab]$',
               ' ', 'g'),
             '[^a-z0-9]', '', 'g')
$$;

DROP TABLE IF EXISTS sec_reference.index_membership_unresolved CASCADE;
DROP TABLE IF EXISTS sec_reference.index_observation_resolved  CASCADE;

CREATE TABLE sec_reference.index_observation_resolved AS
WITH obs AS (
    SELECT o.*, c.sn
    FROM sec_reference.index_observation o
    JOIN sec_reference.index_capture c USING (index_name, observed_on)
),
-- Islands of unbroken presence per (index, ticker), in capture numbers.
runs AS (
    SELECT o.*, o.sn - ROW_NUMBER() OVER (PARTITION BY index_name, ticker ORDER BY sn) AS run_key
    FROM obs o
),
-- Within one unbroken run the ticker is one company. The CIK the page
-- eventually gave it (the earliest capture in the run that has one)
-- applies to the whole run.
run_cik AS (
    SELECT index_name, ticker, run_key,
           (ARRAY_AGG(cik ORDER BY sn) FILTER (WHERE cik IS NOT NULL))[1] AS run_cik,
           MIN(observed_on) AS first_seen, MAX(observed_on) AS last_seen,
           (ARRAY_AGG(name ORDER BY sn DESC))[1] AS last_name
    FROM runs GROUP BY index_name, ticker, run_key
),
spine_names AS (
    SELECT cik, sec_reference.norm_company_name(name) AS n FROM sec_reference.company_name
    UNION
    SELECT cik, sec_reference.norm_company_name(name_latest) FROM sec_reference.company
    UNION
    SELECT DISTINCT cik, sec_reference.norm_company_name(name) FROM sec_silver.sub_silver
),
name_cik AS (
    SELECT rc.index_name, rc.ticker, rc.run_key,
           CASE WHEN COUNT(DISTINCT sn.cik) = 1 THEN MIN(sn.cik) END AS name_cik
    FROM run_cik rc
    JOIN spine_names sn ON sn.n = sec_reference.norm_company_name(rc.last_name) AND sn.n <> ''
    JOIN sec_reference.company co ON co.cik = sn.cik
    WHERE rc.run_cik IS NULL
      AND co.first_filed <= rc.last_seen + 400
      AND co.last_filed  >= rc.first_seen - 400
    GROUP BY rc.index_name, rc.ticker, rc.run_key
)
SELECT r.index_name, r.observed_on, r.revid, r.sn, r.ticker, r.name,
       COALESCE(r.cik, rc.run_cik, nc.name_cik) AS cik,
       CASE WHEN r.cik IS NOT NULL THEN 'page'
            WHEN rc.run_cik IS NOT NULL THEN 'continuity'
            WHEN nc.name_cik IS NOT NULL THEN 'name' END AS cik_source,
       r.gics_sector, r.gics_sub_industry, r.date_added
FROM runs r
JOIN run_cik rc USING (index_name, ticker, run_key)
LEFT JOIN name_cik nc USING (index_name, ticker, run_key);

CREATE INDEX idx_indexobsres_cik ON sec_reference.index_observation_resolved (index_name, cik, observed_on);

CREATE TABLE sec_reference.index_membership_unresolved AS
SELECT index_name, ticker, MIN(name) AS name, MIN(observed_on) AS first_seen, MAX(observed_on) AS last_seen,
       COUNT(*) AS captures
FROM sec_reference.index_observation_resolved
WHERE cik IS NULL
GROUP BY index_name, ticker;

COMMENT ON TABLE sec_reference.index_membership_unresolved IS
    'Constituent tickers that never received a CIK on the page and whose '
    'run of presence ended before the page carried CIKs. Not guessed. '
    'These are members the historical universe is MISSING.';

-- ---------------------------------------------------------------
-- 3. Membership intervals, GICS as of.
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.index_membership CASCADE;

CREATE TABLE sec_reference.index_membership AS
WITH obs AS (
    SELECT index_name, cik, observed_on, sn,
           COALESCE(gics_sector, '') AS gics_sector,
           COALESCE(gics_sub_industry, '') AS gics_sub_industry,
           MIN(ticker) AS ticker,
           MIN(date_added) FILTER (WHERE date_added IS NOT NULL) AS date_added
    FROM sec_reference.index_observation_resolved
    WHERE cik IS NOT NULL
    GROUP BY 1, 2, 3, 4, 5, 6
),
runs AS (
    SELECT o.*, o.sn - ROW_NUMBER() OVER (PARTITION BY index_name, cik, gics_sector, gics_sub_industry
                                          ORDER BY sn) AS run_key
    FROM obs o
),
islands AS (
    SELECT index_name, cik, gics_sector, gics_sub_industry,
           MIN(observed_on) AS first_seen, MAX(observed_on) AS last_seen,
           MIN(sn) AS first_sn, MAX(sn) AS last_sn,
           MIN(date_added) AS date_added,
           (ARRAY_AGG(ticker ORDER BY sn DESC))[1] AS ticker
    FROM runs GROUP BY index_name, cik, gics_sector, gics_sub_industry, run_key
),
neighbours AS (
    SELECT i.*,
           LAG(i.last_sn)   OVER (PARTITION BY index_name, cik, gics_sector, gics_sub_industry ORDER BY first_sn) AS prev_last_sn,
           LAG(i.last_seen) OVER (PARTITION BY index_name, cik, gics_sector, gics_sub_industry ORDER BY first_sn) AS prev_last_seen
    FROM islands i
),
grouped AS (
    SELECT n.*,
           SUM(CASE
                   WHEN n.prev_last_sn IS NULL THEN 1
                   WHEN n.first_seen - n.prev_last_seen <= 200 THEN 0
                   WHEN NOT EXISTS (SELECT 1 FROM sec_reference.index_capture g
                                    WHERE g.index_name = n.index_name
                                      AND g.sn > n.prev_last_sn AND g.sn < n.first_sn
                                      AND NOT g.is_partial) THEN 0
                   ELSE 1
               END) OVER (PARTITION BY index_name, cik, gics_sector, gics_sub_industry
                          ORDER BY first_sn ROWS UNBOUNDED PRECEDING) AS grp
    FROM neighbours n
),
collapsed AS (
    SELECT index_name, cik, gics_sector, gics_sub_industry,
           MIN(first_seen) AS first_seen, MAX(last_sn) AS last_sn,
           MIN(date_added) AS date_added,
           (ARRAY_AGG(ticker ORDER BY last_sn DESC))[1] AS ticker
    FROM grouped GROUP BY index_name, cik, gics_sector, gics_sub_industry, grp
),
history AS (
    SELECT
        c.index_name, c.cik, c.ticker,
        NULLIF(c.gics_sector, '') AS gics_sector,
        NULLIF(c.gics_sub_industry, '') AS gics_sub_industry,
        -- The page's own "date added" where it is earlier than the first
        -- sighting and this is the company's first interval; otherwise
        -- the first capture that showed it. A GICS change mid-membership
        -- starts a new interval at its first capture, contiguous with
        -- the one before.
        CASE WHEN c.date_added IS NOT NULL AND c.date_added < c.first_seen
              AND c.first_seen = MIN(c.first_seen) OVER (PARTITION BY c.index_name, c.cik)
             THEN c.date_added ELSE c.first_seen END AS valid_from,
        -- First capture after the last sighting: earliest evidence of
        -- removal. NULL means present in the latest capture.
        (SELECT MIN(g.observed_on) FROM sec_reference.index_capture g
          WHERE g.index_name = c.index_name AND g.sn > c.last_sn) AS valid_to,
        'wikipedia_history'::TEXT AS source
    FROM collapsed c
),
-- Indexes without replayed history: today's snapshot, labelled as such.
-- One row per company: an issuer with two listed classes in the index
-- (Fox, News Corp) is one member.
snapshot AS (
    SELECT DISTINCT ON (u.index_name, ct.cik)
           u.index_name, ct.cik, u.ticker, u.gics_sector, u.gics_sub_industry,
           DATE '1900-01-01' AS valid_from, NULL::DATE AS valid_to,
           'current_snapshot'::TEXT AS source
    FROM sec_silver.universe_sp1500 u
    JOIN sec_reference.company_ticker ct ON ct.ticker = u.ticker AND ct.valid_to IS NULL
    WHERE NOT EXISTS (SELECT 1 FROM sec_reference.index_observation o WHERE o.index_name = u.index_name)
    ORDER BY u.index_name, ct.cik, ct.is_primary DESC, u.ticker
)
SELECT * FROM history
UNION ALL
SELECT * FROM snapshot;

CREATE UNIQUE INDEX idx_index_membership_key ON sec_reference.index_membership
    (index_name, cik, valid_from, COALESCE(gics_sub_industry, ''));
CREATE INDEX idx_index_membership_cik   ON sec_reference.index_membership (cik, valid_from);
CREATE INDEX idx_index_membership_range ON sec_reference.index_membership (index_name, valid_from, valid_to);

COMMENT ON TABLE sec_reference.index_membership IS
    'Dated index membership per company with GICS as of the interval. '
    'source = wikipedia_history where revisions were replayed (S&P 500), '
    'current_snapshot where only today''s list exists (S&P 400, 600: one '
    'interval from 1900-01-01, i.e. the old survivorship-biased state, '
    'labelled). Member on date D: valid_from <= D AND (valid_to IS NULL '
    'OR valid_to > D).';

-- ---------------------------------------------------------------
-- 3b. The label fallback, one row per company: the membership to use
--     when no interval covers a fact's date. Precomputed because gold
--     needs it for every one of ~110M rows and a per-row LATERAL over
--     index_membership tripled the gold build (46 minutes against 16).
-- ---------------------------------------------------------------
DROP TABLE IF EXISTS sec_reference.index_membership_latest CASCADE;

CREATE TABLE sec_reference.index_membership_latest AS
SELECT DISTINCT ON (cik)
       cik, index_name, gics_sector, gics_sub_industry, source, valid_from, valid_to
FROM sec_reference.index_membership
ORDER BY cik, (valid_to IS NULL) DESC, valid_from DESC;

ALTER TABLE sec_reference.index_membership_latest ADD PRIMARY KEY (cik);

COMMENT ON TABLE sec_reference.index_membership_latest IS
    'One row per company: its current membership if it has one, else its '
    'most recent. The label gold falls back to when no interval covers a '
    'fact''s date (index_is_asof = FALSE).';

-- ---------------------------------------------------------------
-- 4. As-of accessor.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION sec_reference.index_members(p_index TEXT, p_asof DATE)
RETURNS TABLE (cik INTEGER, ticker TEXT, gics_sector TEXT, gics_sub_industry TEXT, source TEXT)
LANGUAGE sql STABLE AS $$
    SELECT m.cik, m.ticker, m.gics_sector, m.gics_sub_industry, m.source
    FROM sec_reference.index_membership m
    WHERE m.index_name = p_index
      AND m.valid_from <= p_asof
      AND (m.valid_to IS NULL OR m.valid_to > p_asof);
$$;

COMMENT ON FUNCTION sec_reference.index_members(TEXT, DATE) IS
    'Constituents of an index on a date, with GICS as of that date. '
    'p_asof has no default. For SP400 and SP600 this is today''s list '
    'at every date until their history is replayed (source says so).';
