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

\echo ''
\echo '=== 11. Ticker coverage (regression guard) ==='
-- Resolving the ticker as of each fact's own availability date left
-- 47.6% of rows NULL, because the crosswalk only covers 2019-02 onward.
-- The fallback should bring that to near zero, and ticker_is_asof says
-- how many carry a date-correct label rather than today's symbol.
SELECT CASE WHEN pct_null < 3 THEN 'PASS' ELSE 'FAIL' END AS status,
       pct_null AS pct_null_ticker,
       pct_asof AS pct_date_correct
FROM (
    SELECT ROUND(100.0*COUNT(*) FILTER (WHERE ticker IS NULL)/COUNT(*),1) AS pct_null,
           ROUND(100.0*COUNT(*) FILTER (WHERE ticker_is_asof)/COUNT(*),1) AS pct_asof
    FROM sec_gold.tradable_financials
) t;

\echo ''
\echo '=== 12. Peer stats carry both levels, sector drops nobody ==='
-- Sub-industry deletes groups below five members outright. Sector
-- should score materially more companies across far fewer groups.
SELECT CASE WHEN sector_cos >= 1490 AND sub_cos > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       sector_groups, sector_cos, sub_groups, sub_cos
FROM (
    SELECT COUNT(DISTINCT peer_group) FILTER (WHERE peer_level='sector')       AS sector_groups,
           COUNT(DISTINCT cik)        FILTER (WHERE peer_level='sector')       AS sector_cos,
           COUNT(DISTINCT peer_group) FILTER (WHERE peer_level='sub_industry') AS sub_groups,
           COUNT(DISTINCT cik)        FILTER (WHERE peer_level='sub_industry') AS sub_cos
    FROM sec_gold.peer_stats
) t;

\echo ''
\echo '=== 13. Concept coverage floors ==='
-- Guards the tag-map work. total_debt was 826 companies and understated;
-- gross_profit 598. A future tag change that silently drops companies
-- should fail here rather than quietly shrink a factor's universe.
WITH cov AS (
    SELECT concept, COUNT(DISTINCT cik) AS n
    FROM sec_gold.peer_stats
    WHERE peer_level='sector' AND fiscal_year=2024
    GROUP BY concept
)
SELECT CASE WHEN
            COALESCE((SELECT n FROM cov WHERE concept='total_debt'),0)   >= 1050
        AND COALESCE((SELECT n FROM cov WHERE concept='gross_profit'),0) >=  830
        AND COALESCE((SELECT n FROM cov WHERE concept='revenue'),0)      >= 1470
       THEN 'PASS' ELSE 'FAIL' END AS status,
       (SELECT n FROM cov WHERE concept='total_debt')     AS total_debt,
       (SELECT n FROM cov WHERE concept='gross_profit')   AS gross_profit,
       (SELECT n FROM cov WHERE concept='revenue')        AS revenue,
       (SELECT n FROM cov WHERE concept='free_cash_flow') AS free_cash_flow;

\echo ''
\echo '=== 14. Derived mechanism actually computes ==='
-- free_cash_flow was declared and excluded everywhere for months. If
-- this resolves, the concept_formula path works end to end.
SELECT CASE WHEN fcf IS NOT NULL AND ocf IS NOT NULL
                 AND abs(fcf - (ocf - COALESCE(cap,0))) < 1
            THEN 'PASS' ELSE 'FAIL' END AS status,
       ROUND(ocf/1e9,2) AS ocf_bn, ROUND(cap/1e9,2) AS capex_bn,
       ROUND(fcf/1e9,2) AS derived_fcf_bn
FROM (
    SELECT sec_gold.get_canonical(320193,'operating_cash_flow',DATE '2025-09-30',4) AS ocf,
           sec_gold.get_canonical(320193,'capex',              DATE '2025-09-30',4) AS cap,
           sec_gold.get_canonical(320193,'free_cash_flow',     DATE '2025-09-30',4) AS fcf
) t;

\echo ''
\echo '=== 15. Equivalent share classes are not double counted ==='
-- Berkshire publishes one total twice, converted into each class's
-- units: EquivalentClassA 1,438,223 and EquivalentClassB 2,157,335,139,
-- a ratio of exactly 1500. Summing them double counts the company.
--
-- This check originally asserted method='class_equivalent', the label of
-- a string-sniffing branch that detected "Equivalent" in the segment
-- text. That branch is gone: the A-side expression is now marked
-- is_excluded in sec_reference.share_class, so it cannot enter the sum
-- at all and the path is the ordinary mapped one. Asserting the label
-- tested the implementation; asserting the value tests the behaviour,
-- which is what should have been checked from the start.
--
-- The number that matters: 2.1572B (B-equivalent alone), NOT the
-- 2.1586B that summing both expressions produced before the fix.
SELECT CASE WHEN shares BETWEEN 2.15e9 AND 2.158e9
                 AND EXISTS (SELECT 1 FROM sec_reference.share_class
                              WHERE cik=1067983 AND class_label='EquivalentClassA'
                                AND is_excluded)
            THEN 'PASS' ELSE 'FAIL' END AS status,
       to_char(shares/1e9,'FM990.0000')||'B' AS brk_shares, method, source_tag
FROM sec_gold.shares_outstanding_at(1067983, CURRENT_DATE);

\echo ''
\echo '=== 16. Multi-class issuers resolve each listed class separately ==='
-- Fox is the control: two classes, two tickers, one to one. If Fox
-- fails the mechanism is broken. Alphabet must show three classes (two
-- listed plus the unlisted B), Liberty Media six across two tracking
-- families that must NOT be pooled.
SELECT CASE WHEN fox=2 AND alphabet=3 AND liberty=6 AND newscorp=2 AND ua=3
            THEN 'PASS' ELSE 'FAIL' END AS status,
       fox, alphabet, liberty, newscorp, ua
FROM (
    SELECT COUNT(*) FILTER (WHERE cik=1754301) AS fox,
           COUNT(*) FILTER (WHERE cik=1652044) AS alphabet,
           COUNT(*) FILTER (WHERE cik=1560385) AS liberty,
           COUNT(*) FILTER (WHERE cik=1564708) AS newscorp,
           COUNT(*) FILTER (WHERE cik=1336917) AS ua
    FROM (
        SELECT DISTINCT cik, class_label FROM sec_gold.share_class_shares
        WHERE cik IN (1754301,1652044,1560385,1564708,1336917)
    ) d
) t;

\echo ''
\echo '=== 17. Alphabet classes reconcile to the consolidated total ==='
-- Class A + Class B + Class C must reach ~12.1B. If the unlisted Class B
-- were dropped the sum would fall about 7% short, so this proves it is
-- carried rather than silently excluded.
SELECT CASE WHEN total BETWEEN 11.5e9 AND 12.7e9 AND n_classes=3 AND n_unlisted=1
            THEN 'PASS' ELSE 'FAIL' END AS status,
       to_char(total/1e9,'FM990.000')||'B' AS class_sum, n_classes, n_unlisted
FROM (
    SELECT SUM(shares) AS total, COUNT(*) AS n_classes,
           COUNT(*) FILTER (WHERE is_unlisted_class) AS n_unlisted
    FROM sec_gold.share_classes_at(1652044, CURRENT_DATE)
) t;

\echo ''
\echo '=== 18. Berkshire is not double counted ==='
-- Berkshire publishes the whole company twice, in A-equivalent and
-- B-equivalent units. Only the B-equivalent expression is mapped; the A
-- one is is_excluded. So exactly one row, priced at BRK-B, and NOT the
-- 2.1586B that summing the two produced before.
SELECT CASE WHEN n_rows=1 AND price_ticker='BRK-B' AND shares < 2.158e9
            THEN 'PASS' ELSE 'FAIL' END AS status,
       n_rows, price_ticker, to_char(shares/1e9,'FM990.000')||'B' AS shares
FROM (
    SELECT COUNT(*) OVER () AS n_rows, price_ticker, shares
    FROM sec_gold.share_classes_at(1067983, CURRENT_DATE) LIMIT 1
) t;

\echo ''
\echo '=== 19. Negative cases produce nothing rather than a wrong number ==='
-- Symbotic (combined V1AndV3 label overlapping its own parts), Xanadu
-- (a literal TotalCommonShares member) and Kodiak (a redemption subset).
-- Each broke a different assumption in the summing logic. None is
-- mapped, so none may contribute a single row.
SELECT CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS rows_from_unmapped_overlapping_issuers
FROM sec_gold.share_class_shares
WHERE cik IN (1837240, 2097163, 1853138)  -- Symbotic, Xanadu, Kodiak
  AND method = 'mapped_class';

\echo ''
\echo '=== 20. Every class row traces to a mapping or a single ticker ==='
-- The allowlist invariant. A row can only exist by explicit mapping or
-- by single-ticker inference; nothing arrives by pattern match.
SELECT CASE WHEN bad=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       total_rows, bad AS rows_with_no_provenance
FROM (
    SELECT COUNT(*) AS total_rows,
           COUNT(*) FILTER (WHERE method NOT IN ('mapped_class','inferred_single')
                               OR price_ticker IS NULL) AS bad
    FROM sec_gold.share_class_shares
) t;

\echo ''
\echo '=== 21. No preferred or compound-axis segment leaked in ==='
-- Regression guard on the contamination bug: the old filter matched
-- ClassOfStock=SeriesAPreferredStock and rows carrying a second axis.
SELECT CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS contaminated_mappings
FROM sec_reference.share_class
WHERE NOT is_excluded
  AND (class_label ILIKE '%preferred%' OR class_label ILIKE '%treasury%'
       OR class_label LIKE '%=%');
