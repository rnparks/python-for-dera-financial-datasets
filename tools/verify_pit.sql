-- Post-rebuild verification for the point-in-time layers.
--
-- Run after `dera build-silver` and `dera build-gold`:
--   psql -d sec_data -f tools/verify_pit.sql
--
-- Every check prints PASS or FAIL with the observed value, so a failure
-- says what went wrong rather than just that something did.

\timing off
\pset footer off

SET statement_timeout = '600s';

\echo '=== 1. Restatements preserved (GE fiscal 2022 revenue) ==='
-- Three distinct vintages, so this exercises the interval boundaries
-- rather than just the endpoints:
--   2023-02-10  10-K  $76.555B   as originally filed
--   2023-04-25  8-K   $58.100B   first restatement
--   2025-02-03  10-K  $29.139B   second restatement
-- An earlier version of this check asserted $76.555B for mid-2023 and
-- failed. The data was right and the assertion was wrong: GE restated
-- in April 2023 via an 8-K, which is exactly the kind of intra-year
-- revision the bitemporal model exists to capture.
WITH v(label, d, expected) AS (VALUES
    ('as first filed',    DATE '2023-03-01', 76555000000::NUMERIC),
    ('after 8-K restate', DATE '2023-06-30', 58100000000::NUMERIC),
    ('after 2025 10-K',   DATE '2025-06-30', 29139000000::NUMERIC)
)
SELECT CASE WHEN bool_and(actual = expected) THEN 'PASS' ELSE 'FAIL' END AS status,
       string_agg(label || '=' || to_char(actual/1e9,'FM990.000') || 'B', ', ' ORDER BY d) AS observed
FROM (
    SELECT v.label, v.d, v.expected,
           (SELECT f.value FROM sec_gold.fact_asof f
             WHERE f.cik=40545 AND f.tag='Revenues' AND f.qtrs=4
               AND f.value_date='2022-12-31'
               AND f.tradable_from <= v.d
               AND (f.superseded_tradable > v.d OR f.superseded_tradable IS NULL)
           ) AS actual
    FROM v
) t;

\echo ''
\echo '=== 2. No look-ahead: nothing in an as-of slice was filed after it ==='
-- The core rule, expressed as an assertion.
SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS rows_knowable_before_they_existed
FROM sec_gold.fact_asof
WHERE tradable_from <= DATE '2020-06-30'
  AND (superseded_tradable > DATE '2020-06-30' OR superseded_tradable IS NULL)
  AND known_at > (DATE '2020-06-30' + INTERVAL '1 day');

\echo ''
\echo '=== 3. Exactly one vintage per fact key in an as-of slice ==='
-- Proves the validity intervals do not overlap.
SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS fact_keys_with_multiple_vintages
FROM (
    SELECT cik, tag, value_date, qtrs, uom
    FROM sec_gold.fact_asof
    WHERE tradable_from <= DATE '2023-06-30'
      AND (superseded_tradable > DATE '2023-06-30' OR superseded_tradable IS NULL)
    GROUP BY 1,2,3,4,5
    HAVING COUNT(*) > 1
) d;

\echo ''
\echo '=== 4. After-close filings are not same-session actionable ==='
-- ~48% of filings are accepted after the bell yet stamped that same
-- filed_date. Every one must roll to a later session.
SELECT CASE WHEN bad = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       total_after_close, bad AS still_same_day
FROM (
    SELECT COUNT(*) AS total_after_close,
           COUNT(*) FILTER (WHERE tradable_from <= (known_at AT TIME ZONE 'America/New_York')::date) AS bad
    FROM sec_silver.sub_silver
    WHERE (known_at AT TIME ZONE 'America/New_York')::time >= TIME '16:00'
) t;

\echo ''
\echo '=== 5. Backfills are flagged (left-censoring stays visible) ==='
-- Coverage starts 2009-04-15, so pre-2011 periods appear mostly as
-- prior-period comparatives, not original disclosures.
SELECT CASE WHEN pct_backfilled > 60 THEN 'PASS' ELSE 'FAIL' END AS status,
       pct_backfilled AS pct_pre2011_flagged_as_comparative
FROM (
    SELECT ROUND(100.0 * COUNT(*) FILTER (WHERE NOT is_original_disclosure)
                 / NULLIF(COUNT(*),0), 1) AS pct_backfilled
    FROM sec_gold.fact_asof
    WHERE qtrs = 4 AND value_date BETWEEN '2008-01-01' AND '2010-12-31'
) t;

\echo ''
\echo '=== 6. Trading calendar excludes known closures ==='
SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS closures_wrongly_present
FROM sec_reference.trading_calendar
WHERE session_date IN ('2012-10-29','2012-10-30','2018-12-05');

\echo ''
\echo '=== 7. Ticker normalization ==='
SELECT CASE WHEN dotted = hyphenated AND dotted > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       dotted AS brk_dot_b, hyphenated AS brk_hyphen_b
FROM (
    SELECT (SELECT COUNT(*) FROM sec_gold.company_snapshot('BRK.B')) AS dotted,
           (SELECT COUNT(*) FROM sec_gold.company_snapshot('BRK-B')) AS hyphenated
) t;

\echo ''
\echo '=== 8. Multi-class companies are not double counted ==='
-- Alphabet reports a consolidated total alongside per-class rows. The
-- resolver must return the consolidated figure, not their sum.
SELECT CASE WHEN shares BETWEEN 11e9 AND 13e9 THEN 'PASS' ELSE 'FAIL' END AS status,
       to_char(shares/1e9,'FM990.000') || 'B' AS alphabet_shares, method, source_tag
FROM sec_gold.shares_outstanding_at(1652044, CURRENT_DATE);

\echo ''
\echo '=== 9. Crosswalk: one primary ticker per overlapping run ==='
SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS ciks_with_overlapping_primaries
FROM (
    SELECT a.cik
    FROM sec_reference.company_ticker a
    JOIN sec_reference.company_ticker b
      ON a.cik = b.cik AND a.ticker < b.ticker
     AND a.is_primary AND b.is_primary
     AND a.valid_from < COALESCE(b.valid_to, '9999-12-31')
     AND b.valid_from < COALESCE(a.valid_to, '9999-12-31')
    GROUP BY a.cik
) d;

\echo ''
\echo '=== 10. Coverage: did the 2026q2 quarter land? ==='
SELECT CASE WHEN max_filed >= DATE '2026-06-01' THEN 'PASS' ELSE 'FAIL' END AS status,
       max_filed AS latest_filing_in_silver, sub_rows
FROM (
    SELECT MAX(filed_date) AS max_filed, COUNT(*) AS sub_rows
    FROM sec_silver.sub_silver
) t;
