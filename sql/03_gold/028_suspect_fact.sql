-- sql/03_gold/028_suspect_fact.sql
--
-- SUSPECT FACTS: the silver rows the gold layer refuses to read. Two
-- reasons, both decided from the filing itself and from filings that
-- were already public when it landed, so a flag never depends on
-- anything that came later: a fact is suspect, or not, from the day
-- it is filed.
--
-- 1. period_after_filing. The period ends after the filing date. A
--    filing cannot report a period that has not ended; this is a
--    mis-dated XBRL context (Catalent's 10-Q of 2024-02-14 carries a
--    nine-month net income "to 2024-03-31"). Read as-is it is a figure
--    knowable before its own period, which is look-ahead by another
--    name. 5,546 facts of 1,047 filers (2026-10-13).
--
-- 2. scale. The filer printed a balance-sheet column in thousands or
--    millions without saying so: Hill-Rom's FY2021 10-K carries total
--    assets of 4,999.1 dollars against 4,671.1 million for FY2020 in the
--    same filing, and 33 other balance lines off by the same million.
--    Read as-is it put a return on assets of 49,709 at the top of every
--    assets-scaled sort. The signature, measured until nothing real was
--    caught (2026-10-12): in one filing, at one period end, FOUR OR MORE
--    tags are each a thousand or a million times SMALLER (within a
--    factor of three) than the same filing's own comparative for the
--    prior period; each comparative agrees (within three) with the
--    figure first filed for it, so the comparative is the trusted side;
--    the largest comparative in the group is at least a million dollars;
--    and either total assets (or total liabilities and equity) is among
--    the tags, or the factor is a million. Total assets of a million or
--    more do not shrink a thousandfold outside liquidation; income and
--    cash-flow lines do (Cliffs' and Valaris' income lines were a
--    thousandfold smaller a year after billion-dollar impairments, with
--    seven lines moving together), so an income-statement column is NOT
--    guarded by this rule, and the larger direction is not used at all
--    (a SPAC's assets grow a thousandfold at its IPO and shrink as much
--    at redemption, and both are real). 87 facts of 8 filers; 42 of
--    them from three S&P 1500 members (2026-10-13).
--
-- NOTHING OVER SOMETHING PLAUSIBLE. A suspect fact is absent from
-- tradable_financials, fact_asof and every function that reads silver
-- directly (get_canonical, latest_annual); a concept at that period
-- resolves to NULL, never to the mis-scaled figure and never to a
-- neighbour's. The list is small, explicit and queryable: reason,
-- reference value and factor are carried so a reader can audit any
-- exclusion in one SELECT.
--
-- BUILD ORDER. Before 030 and 035, which anti-join it. Re-running this
-- file alone DROPs the matview with CASCADE, which drops everything
-- built on it; refresh it with REFRESH MATERIALIZED VIEW (dera
-- build-gold --refresh-only does, first), never by re-running the file
-- outside a full gold build.

DROP MATERIALIZED VIEW IF EXISTS sec_gold.suspect_fact CASCADE;

CREATE MATERIALIZED VIEW sec_gold.suspect_fact AS
WITH f AS (
    -- Undimensioned dollar facts under standard tags, period lengths
    -- the gold layer reads.
    SELECT n.adsh, n.cik, n.tag, n.value_date, n.qtrs, n.value, n.tradable_from
    FROM sec_silver.num_silver n
    WHERE n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD'
      AND n.value IS NOT NULL AND n.value <> 0
      AND n.qtrs BETWEEN 0 AND 4
      AND n.version LIKE 'us-gaap%'
),
-- The filing's own comparative: the nearest earlier period of the same
-- tag and length inside the same filing, within 400 days.
cmp AS (
    SELECT DISTINCT ON (c.adsh, c.tag, c.qtrs, c.value_date)
           c.adsh, c.cik, c.tag, c.qtrs, c.value_date, c.value, c.tradable_from,
           p.value_date AS cmp_date, p.value AS cmp_value
    FROM f c
    JOIN f p ON p.adsh = c.adsh AND p.tag = c.tag AND p.qtrs = c.qtrs
            AND p.value_date < c.value_date AND p.value_date >= c.value_date - 400
    ORDER BY c.adsh, c.tag, c.qtrs, c.value_date, p.value_date DESC
),
-- Only the pairs a thousand or a million apart, the current value the
-- smaller.
small AS (
    SELECT c.*,
           CASE WHEN ABS(c.value) * 1000000 BETWEEN ABS(c.cmp_value) / 3 AND ABS(c.cmp_value) * 3 THEN 1000000
                WHEN ABS(c.value) * 1000    BETWEEN ABS(c.cmp_value) / 3 AND ABS(c.cmp_value) * 3 THEN 1000 END AS factor
    FROM cmp c
    WHERE ABS(c.value) * 1000000 BETWEEN ABS(c.cmp_value) / 3 AND ABS(c.cmp_value) * 3
       OR ABS(c.value) * 1000    BETWEEN ABS(c.cmp_value) / 3 AND ABS(c.cmp_value) * 3
),
-- The comparative's own first disclosure, from an earlier filing that
-- was public when this one landed; it must agree with the comparative
-- for the comparative to be the trusted side.
trusted AS (
    SELECT DISTINCT ON (s.adsh, s.tag, s.qtrs, s.value_date)
           s.*, o.value AS orig_value
    FROM small s
    LEFT JOIN f o ON o.cik = s.cik AND o.tag = s.tag AND o.qtrs = s.qtrs
                 AND o.value_date = s.cmp_date AND o.adsh <> s.adsh
                 AND o.tradable_from <= s.tradable_from
    ORDER BY s.adsh, s.tag, s.qtrs, s.value_date, o.tradable_from ASC
),
candidates AS (
    SELECT t.adsh, t.cik, t.tag, t.value_date, t.qtrs, t.value, t.cmp_value, t.factor
    FROM trusted t
    WHERE t.orig_value IS NULL
       OR ABS(t.orig_value) BETWEEN ABS(t.cmp_value) / 3 AND ABS(t.cmp_value) * 3
),
-- The filing-and-period groups: how many tags moved together, whether
-- total assets is among them, and the largest comparative.
groups AS (
    SELECT c.adsh, c.value_date, c.factor,
           COUNT(*) AS tags_in_filing,
           BOOL_OR(c.tag IN ('Assets', 'LiabilitiesAndStockholdersEquity')
                   AND ABS(c.cmp_value) >= 1000000) AS anchored,
           MAX(ABS(c.cmp_value)) AS max_reference
    FROM candidates c
    GROUP BY c.adsh, c.value_date, c.factor
),
scale AS (
    SELECT c.adsh, c.cik, c.tag, c.value_date, c.qtrs, c.value,
           'scale'::TEXT AS reason, c.cmp_value AS reference_value, c.factor,
           g.tags_in_filing
    FROM candidates c
    JOIN groups g ON g.adsh = c.adsh AND g.value_date = c.value_date AND g.factor = c.factor
    WHERE g.tags_in_filing >= 4
      AND g.max_reference >= 1000000
      AND (g.anchored OR c.factor = 1000000)
),
after_filing AS (
    SELECT n.adsh, n.cik, n.tag, n.value_date, n.qtrs, n.value,
           'period_after_filing'::TEXT AS reason, NULL::NUMERIC AS reference_value,
           NULL::NUMERIC AS factor, 0::BIGINT AS tags_in_filing
    FROM sec_silver.num_silver n
    WHERE n.value_date > n.filed_date
      AND n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD'
)
SELECT adsh, cik, tag, value_date, qtrs, value, reason, reference_value, factor, tags_in_filing::INTEGER AS tags_in_filing
FROM scale
UNION ALL
SELECT adsh, cik, tag, value_date, qtrs, value, reason, reference_value, factor, tags_in_filing::INTEGER
FROM after_filing;

CREATE UNIQUE INDEX idx_suspect_fact_key ON sec_gold.suspect_fact (adsh, tag, value_date, qtrs, reason);
CREATE INDEX idx_suspect_fact_lookup ON sec_gold.suspect_fact (adsh, tag, value_date, qtrs);
CREATE INDEX idx_suspect_fact_cik ON sec_gold.suspect_fact (cik);

-- Statistics now, not at commit: the gold build is one transaction, so
-- autovacuum cannot see this matview until every file after it has
-- already planned against it blind.
ANALYZE sec_gold.suspect_fact;

COMMENT ON MATERIALIZED VIEW sec_gold.suspect_fact IS
    'Silver facts the gold layer refuses: period_after_filing (the period ends after the filing '
    'date) and scale (a balance-sheet column of one filing and period, four or more tags, a '
    'thousand or a million times smaller than the filing''s own trusted comparative). Decided '
    'from the filing and earlier filings only, so a flag never changes with later data. '
    'Anti-joined by 030, 035, 060 and 070.';
