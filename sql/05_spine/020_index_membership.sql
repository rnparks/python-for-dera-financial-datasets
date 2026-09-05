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
-- All three indexes are replayed: the S&P 500 from 2008, the S&P 400
-- from 2011 (no CIK column ever; the dated crosswalk resolves it) and
-- the S&P 600 from 2018 (see section 0 for what its early page was).
-- An index with no observations at all would still fall back to today's
-- snapshot, labelled 'current_snapshot'; none does now.
--
-- Runs after 010_company_spine.sql (it reads company_ticker to check
-- that a resolved CIK really held the ticker) and before 06_security.

-- ---------------------------------------------------------------
-- 0. Sightings: the observations, less the rows that were never the
--    index. THE EARLY S&P 600 PAGE WAS THE S&P 1000. From its first
--    revision (2018-08-30) until 2021-02 the "List of S&P 600 companies"
--    table held 950-1,061 rows: measured on 2019-06-22, 994 rows of which
--    395 were on that month's S&P 400 page and 599 were not. The 599 are
--    the 600. So for an SP600 capture of more than 700 rows, a ticker the
--    closest S&P 400 capture (within 45 days) also lists is a mid-cap and
--    is not a sighting. Evidence-based, not a guess: both pages are
--    captures of the same month. index_observation stays the raw record.
-- ---------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sec_reference.index_sighting (LIKE sec_reference.index_observation INCLUDING ALL);

TRUNCATE sec_reference.index_sighting;
INSERT INTO sec_reference.index_sighting
WITH raw_size AS (
    SELECT index_name, observed_on, COUNT(*) AS n FROM sec_reference.index_observation GROUP BY 1, 2
)
SELECT o.*
FROM sec_reference.index_observation o
JOIN raw_size r USING (index_name, observed_on)
WHERE NOT (
    o.index_name = 'SP600' AND r.n > 700
    AND EXISTS (
        SELECT 1 FROM sec_reference.index_observation m
        WHERE m.index_name = 'SP400' AND m.ticker = o.ticker
          AND m.observed_on = (SELECT x.observed_on FROM raw_size x
                                WHERE x.index_name = 'SP400'
                                  AND x.observed_on BETWEEN o.observed_on - 45 AND o.observed_on + 45
                                ORDER BY ABS(x.observed_on - o.observed_on) LIMIT 1)));

COMMENT ON TABLE sec_reference.index_sighting IS
    'index_observation after the S&P 1000 rule: rows of an oversized '
    'S&P 600 capture that the same month''s S&P 400 page also lists are '
    'removed. What capture quality and membership are derived from.';

-- ---------------------------------------------------------------
-- 1. Capture quality.
-- ---------------------------------------------------------------
-- Declared and refilled in place, like every spine table: see the note
-- at the top of 010_company_spine.sql.
CREATE TABLE IF NOT EXISTS sec_reference.index_capture (
    index_name  TEXT NOT NULL,
    observed_on DATE NOT NULL,
    revid       BIGINT,
    sn          INTEGER,
    n_rows      BIGINT,
    window_max  BIGINT,
    is_partial  BOOLEAN,
    PRIMARY KEY (index_name, observed_on)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_index_capture_sn ON sec_reference.index_capture (index_name, sn);

TRUNCATE sec_reference.index_capture;
INSERT INTO sec_reference.index_capture
SELECT index_name, observed_on, revid,
       ROW_NUMBER() OVER (PARTITION BY index_name ORDER BY observed_on)::INTEGER AS sn,
       n_rows, window_max,
       -- Undersized against its neighbours, or -- for the S&P 600 -- not
       -- about 600 rows after the S&P 1000 subtraction: the two pages
       -- drifted apart from 2019-12 (620-625 rows) and the last S&P 1000
       -- captures (2020-12 to 2021-02) keep 713-755. Such a capture is not
       -- a list of the 600; its sightings are not used and, being partial,
       -- its silence closes nothing, so the bridging rules carry members
       -- seen on both sides across the gap.
       (n_rows < 0.85 * window_max)
       OR (index_name = 'SP600' AND n_rows NOT BETWEEN 570 AND 615) AS is_partial
FROM (
    SELECT index_name, observed_on, revid, n_rows,
           -- An oversized S&P 600 capture is not a list of the 600 and must
           -- not set the bar its neighbours are judged against: with it in
           -- the window every plain 601-row capture of 2021 read as partial.
           MAX(CASE WHEN index_name = 'SP600' AND n_rows NOT BETWEEN 570 AND 615 THEN NULL ELSE n_rows END)
               OVER (PARTITION BY index_name ORDER BY observed_on
                     ROWS BETWEEN 6 PRECEDING AND 6 FOLLOWING) AS window_max
    FROM (SELECT index_name, observed_on, MIN(revid) AS revid, COUNT(*) AS n_rows
          FROM sec_reference.index_sighting GROUP BY 1, 2) c
) s;

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

CREATE TABLE IF NOT EXISTS sec_reference.index_observation_resolved (
    index_name        TEXT,
    observed_on       DATE,
    revid             BIGINT,
    sn                INTEGER,
    ticker            TEXT,
    name              TEXT,
    cik               INTEGER,
    cik_source        TEXT,
    gics_sector       TEXT,
    gics_sub_industry TEXT,
    date_added        DATE
);
CREATE INDEX IF NOT EXISTS idx_indexobsres_cik
    ON sec_reference.index_observation_resolved (index_name, cik, observed_on);
CREATE TABLE IF NOT EXISTS sec_reference.index_membership_unresolved (
    index_name TEXT,
    ticker     TEXT,
    name       TEXT,
    first_seen DATE,
    last_seen  DATE,
    captures   BIGINT
);

TRUNCATE sec_reference.index_observation_resolved, sec_reference.index_membership_unresolved;
INSERT INTO sec_reference.index_observation_resolved
WITH obs AS (
    SELECT o.*, c.sn
    FROM sec_reference.index_sighting o
    JOIN sec_reference.index_capture c USING (index_name, observed_on)
    -- An S&P 600 capture is usable only when what remains after the S&P
    -- 1000 subtraction is about 600 rows. Where the two pages had drifted
    -- apart (2019-12 to 2021-02: 620-756 rows) the derived list was 75-80%
    -- right, which is the kind of plausible-but-wrong the project refuses:
    -- those captures are unused, and partial, so members seen on both
    -- sides bridge across and nobody is invented in between.
    WHERE NOT (o.index_name = 'SP600' AND c.n_rows NOT BETWEEN 570 AND 615)
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
           MIN(observed_on) AS first_seen, MAX(observed_on) AS last_seen,
           (ARRAY_AGG(name ORDER BY sn DESC))[1] AS last_name
    FROM runs GROUP BY index_name, ticker, run_key
),
-- The CIK for a run. The page's CIK column is evidence, not authority:
-- the S&P 1000-era S&P 600 page (2018-2021) carried most CIKs with an
-- extra trailing zero (Southwestern Energy 73320 for 7332, Oceaneering
-- 737560 for 73756) and AAR Corp appears as 17500 in 13 captures. SEC's
-- own dated crosswalk is the authority for which company held a ticker
-- on a date, so: a page CIK the crosswalk confirms wins; if the crosswalk
-- has an answer the page does not match, the crosswalk wins; only when
-- the crosswalk is silent (before 2018-12 for a ticker with no
-- back-extension) does the page's most frequent CIK stand alone. One
-- CIK per run: within an unbroken run the ticker is one company.
run_xw AS (
    SELECT rc.index_name, rc.ticker, rc.run_key,
           sec_reference.cik_at(rc.ticker, rc.last_seen) AS xw_cik
    FROM run_cik rc
),
run_page AS (
    SELECT DISTINCT ON (p.index_name, p.ticker, p.run_key)
           p.index_name, p.ticker, p.run_key, p.cik AS page_cik, x.xw_cik
    FROM (SELECT r.index_name, r.ticker, r.run_key, r.cik, COUNT(*) AS n
          FROM runs r
          -- A CIK that never filed anything is not a CIK; the S&P 1000-era
          -- page's trailing-zero values (73320, 737560 ...) fall out here
          -- and the run resolves through the crosswalk or the name instead.
          WHERE r.cik IS NOT NULL
            AND EXISTS (SELECT 1 FROM sec_reference.company c WHERE c.cik = r.cik)
          GROUP BY 1, 2, 3, 4) p
    JOIN run_xw x USING (index_name, ticker, run_key)
    ORDER BY p.index_name, p.ticker, p.run_key, (p.cik = x.xw_cik) DESC NULLS LAST, p.n DESC
),
run_resolved AS (
    SELECT x.index_name, x.ticker, x.run_key,
           CASE WHEN rp.page_cik IS NOT NULL AND (x.xw_cik IS NULL OR rp.page_cik = x.xw_cik) THEN rp.page_cik
                ELSE x.xw_cik END AS cik,
           CASE WHEN rp.page_cik IS NOT NULL AND (x.xw_cik IS NULL OR rp.page_cik = x.xw_cik) THEN 'page'
                WHEN x.xw_cik IS NOT NULL THEN 'crosswalk' END AS cik_source
    FROM run_xw x
    LEFT JOIN run_page rp USING (index_name, ticker, run_key)
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
    WHERE NOT EXISTS (SELECT 1 FROM run_resolved rr
                       WHERE rr.index_name = rc.index_name AND rr.ticker = rc.ticker
                         AND rr.run_key = rc.run_key AND rr.cik IS NOT NULL)
      AND co.first_filed <= rc.last_seen + 400
      AND co.last_filed  >= rc.first_seen - 400
    GROUP BY rc.index_name, rc.ticker, rc.run_key
)
SELECT r.index_name, r.observed_on, r.revid, r.sn, r.ticker, r.name,
       COALESCE(rr.cik, nc.name_cik) AS cik,
       CASE WHEN rr.cik IS NOT NULL THEN rr.cik_source
            WHEN nc.name_cik IS NOT NULL THEN 'name' END AS cik_source,
       r.gics_sector, r.gics_sub_industry, r.date_added
FROM runs r
JOIN run_cik rc USING (index_name, ticker, run_key)
LEFT JOIN run_resolved rr USING (index_name, ticker, run_key)
LEFT JOIN name_cik nc USING (index_name, ticker, run_key);

INSERT INTO sec_reference.index_membership_unresolved
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
CREATE TABLE IF NOT EXISTS sec_reference.index_membership (
    index_name        TEXT,
    cik               INTEGER,
    ticker            TEXT,
    gics_sector       TEXT,
    gics_sub_industry TEXT,
    valid_from        DATE,
    valid_to          DATE,
    source            TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_index_membership_key ON sec_reference.index_membership
    (index_name, cik, valid_from, COALESCE(gics_sub_industry, ''));
CREATE INDEX IF NOT EXISTS idx_index_membership_cik   ON sec_reference.index_membership (cik, valid_from);
CREATE INDEX IF NOT EXISTS idx_index_membership_range ON sec_reference.index_membership (index_name, valid_from, valid_to);

TRUNCATE sec_reference.index_membership;
INSERT INTO sec_reference.index_membership
WITH obs AS (
    -- One row per (index, company, capture). An issuer listed twice on a
    -- page (two share classes: Fox, News Corp) is one member; if the two
    -- rows disagree on GICS the lower sorts first, deterministically.
    SELECT index_name, cik, observed_on, sn,
           COALESCE(MIN(gics_sector), '')       AS gics_sector,
           COALESCE(MIN(gics_sub_industry), '') AS gics_sub_industry,
           MIN(ticker) AS ticker,
           MIN(date_added) FILTER (WHERE date_added IS NOT NULL) AS date_added
    FROM sec_reference.index_observation_resolved
    WHERE cik IS NOT NULL
    GROUP BY 1, 2, 3, 4
),
-- MEMBERSHIP RUNS PER (INDEX, COMPANY), GICS-BLIND. A company is in or
-- out; the classification the page gave it is an attribute, segmented
-- afterwards inside each span. Partitioning the runs by GICS as well
-- used to open a gap wherever the classification changed -- or first
-- appeared: the S&P 1000-era page carried no GICS at all, so every
-- S&P 600 member fell out of the index between its last unclassified
-- sighting and its first classified one (0 members on 2020-12-30).
runs AS (
    SELECT o.*, o.sn - ROW_NUMBER() OVER (PARTITION BY index_name, cik ORDER BY sn) AS run_key
    FROM obs o
),
islands AS (
    SELECT index_name, cik,
           MIN(observed_on) AS first_seen, MAX(observed_on) AS last_seen,
           MIN(sn) AS first_sn, MAX(sn) AS last_sn
    FROM runs GROUP BY index_name, cik, run_key
),
neighbours AS (
    SELECT i.*,
           LAG(i.last_sn)   OVER (PARTITION BY index_name, cik ORDER BY first_sn) AS prev_last_sn,
           LAG(i.last_seen) OVER (PARTITION BY index_name, cik ORDER BY first_sn) AS prev_last_seen
    FROM islands i
),
-- The same two bridging rules as the crosswalk: seen again within 200
-- days, or every capture in the gap partial (which now includes the
-- S&P 600 captures that were never a list of the 600).
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
               END) OVER (PARTITION BY index_name, cik ORDER BY first_sn ROWS UNBOUNDED PRECEDING) AS grp
    FROM neighbours n
),
spans AS (
    SELECT index_name, cik, grp,
           MIN(first_sn) AS first_sn, MAX(last_sn) AS last_sn, MIN(first_seen) AS first_seen
    FROM grouped GROUP BY index_name, cik, grp
),
spans_to AS (
    -- First capture after the span's last sighting: earliest evidence
    -- of removal. NULL means present in the latest capture.
    SELECT s.*,
           (SELECT MIN(g.observed_on) FROM sec_reference.index_capture g
             WHERE g.index_name = s.index_name AND g.sn > s.last_sn) AS valid_to
    FROM spans s
),
-- GICS segments: consecutive sightings inside a span with the same
-- classification. A change starts a new interval at its first capture,
-- contiguous with the one before; an unclassified stretch is its own
-- segment with NULL GICS rather than a hole in membership.
sightings AS (
    SELECT o.index_name, o.cik, o.sn, o.observed_on, o.gics_sector, o.gics_sub_industry,
           o.ticker, o.date_added, sp.grp, sp.valid_to AS span_valid_to,
           CASE WHEN LAG(o.gics_sector || '|' || o.gics_sub_industry) OVER w IS NULL THEN 0
                WHEN LAG(o.gics_sector || '|' || o.gics_sub_industry) OVER w
                     IS DISTINCT FROM (o.gics_sector || '|' || o.gics_sub_industry) THEN 1
                ELSE 0 END AS new_segment
    FROM obs o
    JOIN spans_to sp ON sp.index_name = o.index_name AND sp.cik = o.cik
                    AND o.sn BETWEEN sp.first_sn AND sp.last_sn
    WINDOW w AS (PARTITION BY o.index_name, o.cik, sp.grp ORDER BY o.sn)
),
segmented AS (
    SELECT x.*,
           SUM(x.new_segment) OVER (PARTITION BY x.index_name, x.cik, x.grp ORDER BY x.sn
                                    ROWS UNBOUNDED PRECEDING) AS seg
    FROM sightings x
),
segments AS (
    SELECT index_name, cik, grp, seg, gics_sector, gics_sub_industry,
           MIN(observed_on) AS first_seen,
           MIN(date_added) AS date_added,
           (ARRAY_AGG(ticker ORDER BY sn DESC))[1] AS ticker,
           MIN(span_valid_to) AS span_valid_to
    FROM segmented
    GROUP BY index_name, cik, grp, seg, gics_sector, gics_sub_industry
),
history AS (
    SELECT
        s.index_name, s.cik, s.ticker,
        NULLIF(s.gics_sector, '')       AS gics_sector,
        NULLIF(s.gics_sub_industry, '') AS gics_sub_industry,
        -- The page's own "date added" where it is earlier than the first
        -- sighting and this is the company's first interval; otherwise
        -- the first capture that showed it.
        CASE WHEN s.seg = 0 AND s.date_added IS NOT NULL AND s.date_added < s.first_seen
              AND s.first_seen = MIN(s.first_seen) OVER (PARTITION BY s.index_name, s.cik)
             THEN s.date_added ELSE s.first_seen END AS valid_from,
        COALESCE(LEAD(s.first_seen) OVER (PARTITION BY s.index_name, s.cik, s.grp ORDER BY s.seg),
                 s.span_valid_to) AS valid_to,
        'wikipedia_history'::TEXT AS source
    FROM segments s
),
-- CIK SUCCESSION. A run resolves to one registrant -- the one holding the
-- ticker at its last sighting -- but a company that re-registered under
-- a new CIK was two registrants across the run: Apache (6769) until APA
-- Corp (1841666) took the ticker in 2021, Cigna 701221 until 1739940 in
-- 2018. An interval that straddles a handoff in cik_succession (010,
-- section 3c) is split there and its earlier part re-keyed to the old
-- CIK, so each interval names the registrant that was filing. Unbroken
-- index presence across the handoff is what makes this a succession
-- rather than a recycled ticker: a recycled ticker changes company only
-- after a removal, which ends the run. Chains (A -> B -> C) are split
-- once per handoff.
history_split AS (
    SELECT h.index_name,
           CASE WHEN x.old_cik IS NOT NULL AND h.valid_from < x.handoff_date THEN x.old_cik ELSE h.cik END AS cik,
           h.ticker, h.gics_sector, h.gics_sub_industry,
           h.valid_from,
           CASE WHEN x.old_cik IS NOT NULL AND h.valid_from < x.handoff_date THEN x.handoff_date ELSE h.valid_to END AS valid_to,
           h.source
    FROM history h
    LEFT JOIN LATERAL (
        SELECT c.old_cik, c.handoff_date
        FROM sec_reference.cik_succession c
        WHERE c.new_cik = h.cik AND c.ticker = h.ticker
          AND c.handoff_date > h.valid_from
          AND c.handoff_date < COALESCE(h.valid_to, DATE '9999-12-31')
        ORDER BY c.handoff_date LIMIT 1
    ) x ON TRUE
    UNION ALL
    -- the part after the handoff stays with the new registrant
    SELECT h.index_name, h.cik, h.ticker, h.gics_sector, h.gics_sub_industry,
           x.handoff_date, h.valid_to, h.source
    FROM history h
    JOIN LATERAL (
        SELECT c.handoff_date
        FROM sec_reference.cik_succession c
        WHERE c.new_cik = h.cik AND c.ticker = h.ticker
          AND c.handoff_date > h.valid_from
          AND c.handoff_date < COALESCE(h.valid_to, DATE '9999-12-31')
        ORDER BY c.handoff_date LIMIT 1
    ) x ON TRUE
),
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
-- A spin-off can put the old registrant on the page twice around the
-- handoff (Crane Co 25445 as CXT, and CR's re-keyed earlier part); one
-- interval per (index, cik, start, classification), the longer kept.
SELECT DISTINCT ON (index_name, cik, valid_from, COALESCE(gics_sub_industry, ''))
       index_name, cik, ticker, gics_sector, gics_sub_industry, valid_from, valid_to, source
FROM (
    SELECT * FROM history_split
    UNION ALL
    SELECT * FROM snapshot
) u
ORDER BY index_name, cik, valid_from, COALESCE(gics_sub_industry, ''), valid_to DESC NULLS FIRST;

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
CREATE TABLE IF NOT EXISTS sec_reference.index_membership_latest (
    cik               INTEGER PRIMARY KEY,
    index_name        TEXT,
    gics_sector       TEXT,
    gics_sub_industry TEXT,
    source            TEXT,
    valid_from        DATE,
    valid_to          DATE
);

TRUNCATE sec_reference.index_membership_latest;
INSERT INTO sec_reference.index_membership_latest
SELECT DISTINCT ON (cik)
       cik, index_name, gics_sector, gics_sub_industry, source, valid_from, valid_to
FROM sec_reference.index_membership
ORDER BY cik, (valid_to IS NULL) DESC, valid_from DESC;

COMMENT ON TABLE sec_reference.index_membership_latest IS
    'One row per company: its current membership if it has one, else its '
    'most recent. The label gold falls back to when no interval covers a '
    'fact''s date (index_is_asof = FALSE).';

-- ---------------------------------------------------------------
-- 3c. The membership timeline: one NON-OVERLAPPING interval set per
--     company, so gold can join it with a plain range condition.
-- ---------------------------------------------------------------
-- index_membership can hold several intervals covering one date for a
-- company: a replayed S&P 500 span inside a snapshot S&P 400 span that
-- starts at 1900-01-01, or a GICS reclassification. Gold used to resolve
-- that per fact with LATERAL ... ORDER BY ... LIMIT 1, which forces a
-- nested loop with a sort for every one of ~100M rows and took the gold
-- build from 16 to 32 minutes. Here the same precedence -- replayed
-- history beats a snapshot, then the later start -- is applied once per
-- boundary segment and stored as a timeline that never overlaps, so a
-- join on cik plus the date range is single-valued by construction and
-- the planner is free to hash it. The EXCLUDE constraint makes the
-- non-overlap a property of the table rather than a convention.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE IF NOT EXISTS sec_reference.index_membership_timeline (
    cik               INTEGER NOT NULL,
    valid_from        DATE    NOT NULL,
    valid_to          DATE,
    index_name        TEXT    NOT NULL,
    gics_sector       TEXT,
    gics_sub_industry TEXT,
    source            TEXT    NOT NULL,
    PRIMARY KEY (cik, valid_from),
    CONSTRAINT index_membership_timeline_ordered
        CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT index_membership_timeline_no_overlap
        EXCLUDE USING gist (cik WITH =, daterange(valid_from, valid_to) WITH &&)
);

TRUNCATE sec_reference.index_membership_timeline;
INSERT INTO sec_reference.index_membership_timeline
WITH bounds AS (
    SELECT cik, valid_from AS b FROM sec_reference.index_membership
    UNION
    SELECT cik, valid_to FROM sec_reference.index_membership WHERE valid_to IS NOT NULL
),
segments AS (
    SELECT cik, b AS seg_from,
           LEAD(b) OVER (PARTITION BY cik ORDER BY b) AS seg_to
    FROM bounds
),
-- The winner for each segment, by the precedence gold used per fact.
-- A segment nothing covers (after every interval closed) has no row.
resolved AS (
    SELECT s.cik, s.seg_from, s.seg_to,
           w.index_name, w.gics_sector, w.gics_sub_industry, w.source
    FROM segments s
    JOIN LATERAL (
        SELECT m.index_name, m.gics_sector, m.gics_sub_industry, m.source
        FROM sec_reference.index_membership m
        WHERE m.cik = s.cik
          AND m.valid_from <= s.seg_from
          AND (m.valid_to IS NULL OR m.valid_to > s.seg_from)
        ORDER BY (m.source = 'wikipedia_history') DESC, m.valid_from DESC
        LIMIT 1
    ) w ON TRUE
),
-- Adjacent segments with the same answer collapse into one interval.
flagged AS (
    SELECT r.*,
           CASE WHEN LAG(r.seg_to) OVER w = r.seg_from
                 AND LAG(r.index_name) OVER w = r.index_name
                 AND LAG(r.gics_sector) OVER w IS NOT DISTINCT FROM r.gics_sector
                 AND LAG(r.gics_sub_industry) OVER w IS NOT DISTINCT FROM r.gics_sub_industry
                 AND LAG(r.source) OVER w = r.source
                THEN 0 ELSE 1 END AS new_run
    FROM resolved r
    WINDOW w AS (PARTITION BY r.cik ORDER BY r.seg_from)
),
runs AS (
    SELECT f.*,
           SUM(f.new_run) OVER (PARTITION BY f.cik ORDER BY f.seg_from
                                ROWS UNBOUNDED PRECEDING) AS run_id
    FROM flagged f
)
SELECT cik,
       MIN(seg_from),
       CASE WHEN bool_or(seg_to IS NULL) THEN NULL ELSE MAX(seg_to) END,
       MIN(index_name), MIN(gics_sector), MIN(gics_sub_industry), MIN(source)
FROM runs
GROUP BY cik, run_id;

COMMENT ON TABLE sec_reference.index_membership_timeline IS
    'index_membership resolved to one non-overlapping interval set per '
    'company (replayed history beats a snapshot, then the later start). '
    'What gold joins on: member on date D is the single row with '
    'valid_from <= D AND (valid_to IS NULL OR valid_to > D).';

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
