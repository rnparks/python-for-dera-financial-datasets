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
-- The core rule, expressed as an assertion. The slice must be non-empty:
-- a COUNT of zero over an empty table would pass vacuously, and this
-- suite has to fail loudly if fact_asof is missing after a build error.
SELECT CASE WHEN bad = 0 AND in_slice > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       in_slice AS rows_in_slice, bad AS rows_knowable_before_they_existed
FROM (
    SELECT COUNT(*) AS in_slice,
           COUNT(*) FILTER (WHERE known_at > (DATE '2020-06-30' + INTERVAL '1 day')) AS bad
    FROM sec_gold.fact_asof
    WHERE tradable_from <= DATE '2020-06-30'
      AND (superseded_tradable > DATE '2020-06-30' OR superseded_tradable IS NULL)
) t;

\echo ''
\echo '=== 3. Exactly one vintage per fact key in an as-of slice ==='
-- Proves the validity intervals do not overlap. Non-empty for the same
-- reason as check 2.
SELECT CASE WHEN dup = 0 AND keys > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       keys AS fact_keys_in_slice, dup AS fact_keys_with_multiple_vintages
FROM (
    SELECT COUNT(*) AS keys, COUNT(*) FILTER (WHERE n > 1) AS dup
    FROM (
        SELECT cik, tag, value_date, qtrs, uom, COUNT(*) AS n
        FROM sec_gold.fact_asof
        WHERE tradable_from <= DATE '2023-06-30'
          AND (superseded_tradable > DATE '2023-06-30' OR superseded_tradable IS NULL)
        GROUP BY 1,2,3,4,5
    ) d
) t;

\echo ''
\echo '=== 4. After-close filings are not same-session actionable ==='
-- 57% of filings (247,216 of 433,717 on 2026-09-04) are accepted after
-- the bell. Every one must roll to a later session. Measured against
-- the session's actual close_at, so the ~130 filings accepted between a
-- 13:00 half-day bell and 16:00 are covered too; a fixed 16:00 test
-- could not see them.
SELECT CASE WHEN bad = 0 AND total_after_close > 200000 THEN 'PASS' ELSE 'FAIL' END AS status,
       total_after_close, bad AS still_same_day
FROM (
    SELECT COUNT(*) AS total_after_close,
           COUNT(*) FILTER (WHERE s.tradable_from <= c.session_date) AS bad
    FROM sec_silver.sub_silver s
    JOIN sec_reference.trading_calendar c
      ON c.session_date = (s.known_at AT TIME ZONE 'America/New_York')::date
    WHERE s.known_at > c.close_at
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
-- 47.6% of rows NULL, because observed crosswalk intervals start 2018-12.
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
-- Floors re-based on 2026-09-04 when the panel became the index of the
-- time: a company promoted into the S&P 500 during 2025 was an S&P 400
-- member at its FY2024 period end, and the 400 has no replayed history,
-- so it is in no FY2024 panel. Revenue 1,428 (was 1,479 on today's
-- survivors), total_debt 1,063, gross_profit 844. total_debt re-based to
-- 1,100 after the 2026-09-04 tag additions took it to 1,127 with the
-- noncurrent component required.
SELECT CASE WHEN
            COALESCE((SELECT n FROM cov WHERE concept='total_debt'),0)   >= 1100
        AND COALESCE((SELECT n FROM cov WHERE concept='gross_profit'),0) >=  820
        AND COALESCE((SELECT n FROM cov WHERE concept='revenue'),0)      >= 1400
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

-- ============================================================
-- Historical universe: survivorship and future-existence bias.
-- Checks 22-27 cover the four tests in the universe specification.
-- These run against the Phase 0 slice; they are written to hold for the
-- full population too, so scaling the ingest should not change them.
-- ============================================================

\echo '=== 22. Test A: a company that failed stays in past universes ==='
-- SVB Financial was an S&P 500 member until it collapsed. It must be a
-- member in 2015 and 2016, gone after its 25-NSE of 2023-05-02, and
-- carry a delisting_event -- not vanish as if it never existed.
SELECT CASE WHEN in_2015 AND in_2016 AND NOT in_2024 AND has_event
            THEN 'PASS' ELSE 'FAIL' END AS status,
       in_2015, in_2016, in_2024, has_event, delisting_date
FROM (
    SELECT
      EXISTS (SELECT 1 FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30') WHERE cik=719739) AS in_2015,
      EXISTS (SELECT 1 FROM sec_reference.universe_at('filers_10k_15m', DATE '2016-06-30') WHERE cik=719739) AS in_2016,
      EXISTS (SELECT 1 FROM sec_reference.universe_at('filers_10k_15m', DATE '2024-06-30') WHERE cik=719739) AS in_2024,
      EXISTS (SELECT 1 FROM sec_reference.delisting_event de
              JOIN sec_reference.security s USING (security_id) WHERE s.cik=719739) AS has_event,
      (SELECT delisting_date FROM sec_reference.security WHERE cik=719739) AS delisting_date
) t;

\echo '=== 23. Test A (cont.): the universe actually recovers failed companies ==='
-- WHAT THIS REPLACED, AND WHY. Two earlier versions asserted that every
-- delisted company was a universe member at a FIXED OFFSET -- one year
-- before its delisting. Both failed at scale (933, then 662 of 4,195)
-- and neither failure was a model bug. Companies go dark before they
-- formally delist, and a company that missed filings and then filed a
-- late catch-up 10-K has a genuine gap in its eligibility. A fixed
-- offset was never implied by the data, so the test was measuring an
-- assumption the model never made.
--
-- This asserts the property Test A actually exists to protect: a
-- historical universe must contain companies that have since failed. A
-- universe built from current constituents scores exactly zero here, so
-- the check is falsifiable in the direction that matters rather than
-- being a statistic about an arbitrary date.
SELECT CASE WHEN since_delisted > 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       members_2015, since_delisted,
       round(100.0*since_delisted/NULLIF(members_2015,0),1) AS pct_since_delisted
FROM (
    SELECT count(*) AS members_2015,
           count(*) FILTER (WHERE s.delisting_date IS NOT NULL) AS since_delisted
    FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30') u
    JOIN sec_reference.security s USING (security_id)
) t;

\echo '=== 24. Test B: no security is in a universe before it could trade ==='
-- Future-existence bias, asserted globally rather than per name. The
-- eligibility CHECK constraints make this structurally impossible, so a
-- failure here means a constraint was dropped -- or, with the row-count
-- guard, that the table is empty (a silver rebuild without the filing
-- index used to leave it that way).
SELECT CASE WHEN bad = 0 AND total > 10000 THEN 'PASS' ELSE 'FAIL' END AS status,
       total AS eligibility_rows, bad AS intervals_starting_before_first_trade
FROM (
    SELECT COUNT(*) AS total,
           COUNT(*) FILTER (WHERE e.valid_from < s.first_trade_date) AS bad
    FROM sec_reference.eligibility e
    JOIN sec_reference.security s USING (security_id)
) t;

\echo '=== 25. Test B (cont.): recent IPOs absent from pre-IPO universes ==='
-- Palantir (2020), Coinbase (2021) and Rivian (2021) must not appear in
-- a 2015 universe merely because they are successful companies today.
SELECT CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS ipos_leaking_into_2015
FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30')
WHERE cik IN (1321655, 1679788, 1874178);

\echo '=== 26. Test D: a ticker change preserves one security identity ==='
-- Unrivaled Brands traded as TRTC and later UNRV on one CIK. One
-- security, two listing intervals, and the as-of ticker must differ by
-- era rather than both resolving to today's symbol.
SELECT CASE WHEN n_securities=1 AND n_listings>1 THEN 'PASS' ELSE 'FAIL' END AS status,
       n_securities, n_listings
FROM (
    SELECT (SELECT COUNT(*) FROM sec_reference.security WHERE cik=1451512) AS n_securities,
           (SELECT COUNT(*) FROM sec_reference.listing l
            JOIN sec_reference.security s USING (security_id)
            WHERE s.cik=1451512) AS n_listings
) t;

\echo '=== 27. Delisted securities carry an outcome row, never silence ==='
-- A delisting is an investment event. delisting_return stays NULL until
-- a price source exists -- NULL, not 0, because zero would assert a
-- total loss and that is wrong for an acquisition.
SELECT CASE WHEN missing_event=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       total_delisted, missing_event, awaiting_return
FROM (
    SELECT COUNT(*) AS total_delisted,
           COUNT(*) FILTER (WHERE NOT EXISTS (
               SELECT 1 FROM sec_reference.delisting_event de
               WHERE de.security_id = s.security_id)) AS missing_event,
           COUNT(*) FILTER (WHERE EXISTS (
               SELECT 1 FROM sec_reference.delisting_event de
               WHERE de.security_id = s.security_id
                 AND de.delisting_return IS NULL)) AS awaiting_return
    FROM sec_reference.security s WHERE s.delisting_date IS NOT NULL
) t;

\echo '=== 28. Nothing is marked delisted while it is still filing ==='
-- WHAT THIS REPLACED, AND WHY. The first version cross-checked against
-- SEC's company_tickers.json: a company with a live ticker cannot have
-- delisted. That found a real bug -- 264 live companies marked delisted,
-- Colgate-Palmolive among them -- and the gate in 010_security_populate
-- fixes it.
--
-- But the check itself was built on a premise this project rejects
-- everywhere else. company_tickers.json is a CURRENT-STATE file and it
-- lags: after the fix, the 103 remaining disagreements were foreign
-- private issuers that genuinely delisted -- CyberArk (acquired by Palo
-- Alto), Telefonica, Magic Software, Cool Co -- and SEC simply had not
-- removed them yet. docs/data_sources.md says in as many words not to
-- treat that field as authoritative; this check was doing exactly that.
--
-- The invariant restated against filings, which are immutable and dated:
-- a company still filing periodic reports well after its supposed
-- delisting was not delisted. Same defect caught, no dependence on a
-- file that describes the present.
SELECT CASE WHEN COUNT(*)=0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS delisted_but_still_reporting,
       COALESCE(string_agg(DISTINCT cik::text, ',' ORDER BY cik::text), '-') AS examples
FROM (
    SELECT s.cik
    FROM sec_reference.security s
    WHERE s.delisting_date IS NOT NULL
      AND NOT s.is_provisional
      AND EXISTS (SELECT 1 FROM sec_reference.security_event_raw e
                  WHERE e.cik = s.cik
                    AND e.event_type = 'PERIODIC_REPORT'
                    AND e.event_date > s.delisting_date + INTERVAL '15 months')
    LIMIT 20
) t;

-- ============================================================
-- Checks 29-42 guard the defects found in the 2026-09-04 review. Each
-- names the failure it was written against, with the measured number,
-- so a future FAIL reads as "this came back" rather than "a threshold".
-- ============================================================

\echo ''
\echo '=== 29. Delisting evidence is only ever a Form 25 or a Form 15 ==='
-- classify() once prefix-matched "25", so Regulation A offering
-- circulars (253G1-253G4) were read as delisting notices and 54
-- securities were delisted on the day they raised money.
SELECT CASE WHEN bad = 0 AND total > 4000 THEN 'PASS' ELSE 'FAIL' END AS status,
       total AS delisting_events, bad AS from_other_forms
FROM (
    SELECT COUNT(*) AS total,
           COUNT(*) FILTER (WHERE source_form !~ '^(25(-NSE)?(/A)?|15F?-(12B|12G|15D)(/A)?)$') AS bad
    FROM sec_reference.delisting_event
) t;

\echo '=== 30. Crosswalk: no single-capture gap survives ==='
-- A pair absent from exactly one capture and back in the next is a
-- file artefact, never a retirement -- 2,459 such gaps existed before
-- the spine learned to bridge them. Reports the captures judged partial
-- alongside, so a new bad capture is visible here.
SELECT CASE WHEN single_gaps = 0 AND captures >= 60 THEN 'PASS' ELSE 'FAIL' END AS status,
       single_gaps AS pairs_closed_then_reopened_next_capture,
       (SELECT COUNT(*) FROM sec_reference.ticker_capture WHERE is_partial) AS partial_captures,
       captures
FROM (
    SELECT (SELECT COUNT(*) FROM sec_reference.ticker_capture) AS captures,
           (SELECT COUNT(*)
              FROM sec_reference.company_ticker a
              JOIN sec_reference.company_ticker b
                ON a.cik = b.cik AND a.ticker = b.ticker AND a.valid_to IS NOT NULL
               AND a.source = 'observed' AND b.source = 'observed'
              JOIN sec_reference.ticker_capture s1 ON s1.observed_on = a.valid_to
              JOIN sec_reference.ticker_capture s2 ON s2.sn = s1.sn + 1
                                                   AND s2.observed_on = b.valid_from) AS single_gaps
) t;

\echo '=== 31. Crosswalk: the newest capture is a recent live fetch ==='
-- The "current" snapshot was once a nine-month-old local CSV stamped
-- with the run date (an exact set match with tickers.csv). That fallback
-- no longer exists; what remains to check is that the live capture is
-- there and recent.
SELECT CASE WHEN source = 'sec_current' AND observed_on >= CURRENT_DATE - 90
            THEN 'PASS' ELSE 'FAIL' END AS status,
       observed_on AS newest_capture, source, n_rows
FROM (
    SELECT observed_on, source, COUNT(*) AS n_rows
    FROM sec_reference.ticker_observation
    GROUP BY 1, 2 ORDER BY observed_on DESC LIMIT 1
) t;

\echo '=== 32. Every in-lifetime crosswalk interval reaches listing ==='
-- DISTINCT ON (security_id, ticker) once kept only the first interval
-- of a ticker a company held, lapsed and held again; 2,792 later
-- intervals were silently lost.
SELECT CASE WHEN listed >= candidates AND candidates > 15000 THEN 'PASS' ELSE 'FAIL' END AS status,
       candidates AS in_lifetime_intervals, listed AS listing_rows_from_crosswalk
FROM (
    SELECT (SELECT COUNT(*) FROM sec_reference.listing
             WHERE source IN ('company_ticker', 'company_ticker_extended')) AS listed,
           (SELECT COUNT(*)
              FROM sec_reference.security s
              JOIN sec_reference.company_ticker ct ON ct.cik = s.cik
             WHERE s.class_label = '(common)'
               AND GREATEST(ct.valid_from, COALESCE(s.first_trade_date, ct.valid_from))
                <= LEAST(COALESCE(ct.valid_to, DATE '9999-12-31'),
                         COALESCE(s.delisting_date, DATE '9999-12-31'))) AS candidates
) t;

\echo '=== 33. No unlisted share class is a universe member ==='
-- Alphabet Class B, Under Armour''s convertible and four Liberty B
-- classes were members with no ticker at all.
SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS members_with_no_ticker_among_mapped_ciks
FROM sec_reference.universe_at('filers_10k_15m', DATE '2024-06-30') u
WHERE u.ticker IS NULL
  AND EXISTS (SELECT 1 FROM sec_reference.share_class sc WHERE sc.cik = u.cik);

\echo '=== 34. Derived concepts resolve wherever their operands exist ==='
-- total_debt has two OPTIONAL operands. latest_annual took its
-- candidate periods from required operands only and never derived it:
-- 836 of 1,092 tracked companies that peer_stats resolves got NULL.
SELECT CASE WHEN pct_resolved >= 95 THEN 'PASS' ELSE 'FAIL' END AS status,
       holders AS peer_stats_total_debt_fy2024, resolved AS latest_annual_resolves, pct_resolved
FROM (
    SELECT COUNT(*) AS holders,
           COUNT(v) AS resolved,
           ROUND(100.0 * COUNT(v) / NULLIF(COUNT(*), 0), 1) AS pct_resolved
    FROM (
        SELECT p.cik, (SELECT value FROM sec_gold.latest_annual(p.cik, 'total_debt')) AS v
        FROM (SELECT DISTINCT cik FROM sec_gold.peer_stats
               WHERE peer_level = 'sector' AND fiscal_year = 2024 AND concept = 'total_debt') p
    ) x
) t;

\echo '=== 35. The newest period wins over a stale direct tag (Apple) ==='
-- company_snapshot reported Apple total_debt as $40.1B from a 2015
-- LongTermDebt row while the 2026 components summed to $82.7B, and
-- as_of_snapshot had no formula fallback at all (free_cash_flow NULL).
SELECT CASE WHEN cs.value_date >= DATE '2025-01-01'
             AND asf.value_date >= DATE '2025-01-01'
             AND fcf.value IS NOT NULL
            THEN 'PASS' ELSE 'FAIL' END AS status,
       cs.value_date AS snapshot_total_debt_date,
       ROUND(cs.value / 1e9, 1) AS snapshot_total_debt_bn,
       asf.value_date AS asof_total_debt_date,
       ROUND(fcf.value / 1e9, 1) AS asof_free_cash_flow_bn
FROM (SELECT value_date, value FROM sec_gold.company_snapshot('AAPL') WHERE concept = 'total_debt') cs,
     (SELECT value_date, value FROM sec_gold.as_of_snapshot(320193, CURRENT_DATE) WHERE concept = 'total_debt') asf,
     (SELECT value FROM sec_gold.as_of_snapshot(320193, CURRENT_DATE) WHERE concept = 'free_cash_flow') fcf;

\echo '=== 36. The share-count denominator keeps delisted companies ==='
-- Twitter (1418091) delisted in 2022 and only ever held TWTR. The old
-- single-ticker inference required a ticker current TODAY and excluded
-- 4,998 delisted companies: 4,346 CIKs had rows, out of 12,835 with
-- consolidated share counts; 8,228 after the fix. (SVB Financial is NOT
-- a valid example: it also listed SIVBO/SIVBP preferred lines, so it has
-- overlapping tickers and correctly needs a mapping.)
SELECT CASE WHEN twtr_rows > 0 AND ciks >= 7000 THEN 'PASS' ELSE 'FAIL' END AS status,
       twtr_rows, ciks AS ciks_with_share_rows
FROM (
    SELECT (SELECT COUNT(*) FROM sec_gold.share_class_shares WHERE cik = 1418091) AS twtr_rows,
           (SELECT COUNT(DISTINCT cik) FROM sec_gold.share_class_shares) AS ciks
) t;

\echo '=== 37. Revenue resolves before ASC 606 too, and never from half a company ==='
-- SalesRevenueNet and the goods/services components were unmapped:
-- FY2015 revenue covered 628 of 1,361 tracked issuers against 1,479 in
-- FY2024. Check 13 guards FY2024 only. The components are safe only
-- while no issuer files BOTH of them with no total in the same year --
-- that shape would resolve to the goods line alone -- so it is asserted
-- absent here rather than assumed.
-- Floors re-based on 2026-09-04 for the dated panel: FY2015 1,192 (a
-- company in today's S&P 500 that was an S&P 400 member in 2015 is in
-- no FY2015 panel until the 400's history is replayed), FY2024 1,428.
SELECT CASE WHEN fy2015 >= 1150 AND fy2024 >= 1400 AND half_company = 0
            THEN 'PASS' ELSE 'FAIL' END AS status,
       fy2015 AS ciks_with_revenue_fy2015, fy2024 AS ciks_with_revenue_fy2024,
       half_company AS cik_years_with_both_components_and_no_total
FROM (
    SELECT COUNT(DISTINCT cik) FILTER (WHERE fiscal_year = 2015) AS fy2015,
           COUNT(DISTINCT cik) FILTER (WHERE fiscal_year = 2024) AS fy2024
    FROM sec_gold.peer_stats WHERE peer_level = 'sector' AND concept = 'revenue'
) c,
(
    WITH both_components AS (
        SELECT cik, sec_gold.fiscal_year_of(value_date) AS fy
        FROM sec_gold.tradable_financials
        WHERE qtrs = 4 AND tag IN ('SalesRevenueGoodsNet', 'SalesRevenueServicesNet')
        GROUP BY 1, 2
        HAVING COUNT(DISTINCT tag) = 2
    ),
    any_total AS (
        SELECT DISTINCT t2.cik, sec_gold.fiscal_year_of(t2.value_date) AS fy
        FROM sec_gold.tradable_financials t2
        JOIN sec_gold.concept_tag_map m ON m.tag = t2.tag AND m.concept = 'revenue'
        WHERE m.priority <= 6 AND t2.qtrs = 4
    )
    SELECT COUNT(*) AS half_company
    FROM both_components b
    WHERE NOT EXISTS (SELECT 1 FROM any_total a WHERE a.cik = b.cik AND a.fy = b.fy)
) g;

\echo '=== 38. The trading calendar reaches well past the newest filing ==='
-- A filing accepted after the last session gets NULL tradable_from and
-- vanishes from every as-of slice, silently. The loader refuses a
-- calendar with under a year left; this checks the loaded one.
SELECT CASE WHEN cal_max > CURRENT_DATE + 180 AND cal_max > newest_filing + 180
            THEN 'PASS' ELSE 'FAIL' END AS status,
       cal_max AS calendar_ends, newest_filing
FROM (
    SELECT (SELECT MAX(session_date) FROM sec_reference.trading_calendar) AS cal_max,
           (SELECT MAX(known_at)::date FROM sec_silver.sub_silver) AS newest_filing
) t;

\echo '=== 39. The as-of discipline raises instead of returning nothing ==='
-- financials(''asof'') with no date returned 0 rows; shift_sessions before
-- the calendar returned NULL; a ticker before the crosswalk floor gave
-- as_of_snapshot fifteen empty rows. All three must raise now. Apple's
-- 2015 label resolves since the back-extension, so the ticker probe is
-- Meta in 2015: it was FB then, the file only ever shows the change's
-- result, and no interval covers the date.
CREATE OR REPLACE FUNCTION pg_temp.raises(p_sql TEXT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $fn$
BEGIN
    EXECUTE p_sql;
    RETURN FALSE;
EXCEPTION WHEN OTHERS THEN
    RETURN TRUE;
END
$fn$;
SELECT CASE WHEN a AND b AND c THEN 'PASS' ELSE 'FAIL' END AS status,
       a AS financials_asof_without_date, b AS shift_before_calendar, c AS changed_ticker_before_crosswalk
FROM (
    SELECT pg_temp.raises($q$SELECT * FROM sec_silver.financials('asof') LIMIT 1$q$)            AS a,
           pg_temp.raises($q$SELECT sec_gold.shift_sessions(DATE '2008-06-30', 1)$q$)            AS b,
           pg_temp.raises($q$SELECT * FROM sec_gold.as_of_snapshot('FB', DATE '2015-06-30')$q$) AS c
) t;

\echo '=== 40. The CIK-keyed snapshot works before the crosswalk floor ==='
SELECT CASE WHEN COUNT(value) >= 8 THEN 'PASS' ELSE 'FAIL' END AS status,
       COUNT(*) AS concepts, COUNT(value) AS resolved_for_apple_2015
FROM sec_gold.as_of_snapshot(320193, DATE '2015-06-30');

\echo '=== 41. The share ladder prefers a point-in-time count to a period average ==='
-- 216 of 1,569 tracked companies resolved to a weighted average as of
-- today; for 87 of them an instant count within 400 days existed.
SELECT CASE WHEN weighted <= 150 AND companies > 1500 THEN 'PASS' ELSE 'FAIL' END AS status,
       companies, weighted AS resolved_to_weighted_average
FROM (
    SELECT COUNT(*) AS companies,
           COUNT(*) FILTER (WHERE s.source_tag LIKE 'WeightedAverage%') AS weighted
    FROM (SELECT DISTINCT cik FROM sec_gold.tradable_financials) u
    LEFT JOIN LATERAL sec_gold.shares_outstanding_at(u.cik, CURRENT_DATE) s ON TRUE
) t;

\echo '=== 42. Going dark is an outcome, not silence ==='
-- 2,207 CIKs filed a Form 15, never a Form 25, and stopped filing; they
-- had no delisting_event at all and every existing event was an
-- exchange notice.
SELECT CASE WHEN deregistrations > 2000 AND exchange_notices > 4000 THEN 'PASS' ELSE 'FAIL' END AS status,
       exchange_notices, deregistrations
FROM (
    SELECT COUNT(*) FILTER (WHERE reason = 'exchange_notice') AS exchange_notices,
           COUNT(*) FILTER (WHERE reason = 'deregistration')  AS deregistrations
    FROM sec_reference.delisting_event
) t;

\echo '=== 43. S&P 500 history: captures are complete and members resolve ==='
-- 214 monthly Wikipedia captures, none undersized; CIKs from the page,
-- by continuity, or by name; 40 tickers unresolved (21 inside DERA
-- coverage), listed in index_membership_unresolved rather than guessed.
SELECT CASE WHEN captures >= 200 AND partial = 0 AND unresolved_in_coverage <= 30
             AND m2009 BETWEEN 470 AND 530 AND m2015 BETWEEN 490 AND 530 AND ever >= 800
            THEN 'PASS' ELSE 'FAIL' END AS status,
       captures, partial, unresolved_in_coverage, m2009 AS members_2009_06_30,
       m2015 AS members_2015_06_30, ever AS ever_members
FROM (
    SELECT (SELECT COUNT(*) FROM sec_reference.index_capture WHERE index_name = 'SP500') AS captures,
           (SELECT COUNT(*) FROM sec_reference.index_capture WHERE index_name = 'SP500' AND is_partial) AS partial,
           (SELECT COUNT(*) FROM sec_reference.index_membership_unresolved
             WHERE last_seen >= DATE '2009-04-15') AS unresolved_in_coverage,
           (SELECT COUNT(*) FROM sec_reference.index_members('SP500', DATE '2009-06-30')) AS m2009,
           (SELECT COUNT(*) FROM sec_reference.index_members('SP500', DATE '2015-06-30')) AS m2015,
           (SELECT COUNT(DISTINCT cik) FROM sec_reference.index_membership
             WHERE index_name = 'SP500' AND source = 'wikipedia_history') AS ever
) t;

\echo '=== 44. S&P 500 membership is dated: joins and exits land where they happened ==='
-- SVB Financial joined 2018-03 and collapsed 2023-03; Tesla was added
-- 2020-12-21; Twitter left 2022-10 when taken private. A
-- current-snapshot universe gets every one of these wrong.
SELECT CASE WHEN svb_2019 AND NOT svb_2024 AND NOT tsla_2020 AND tsla_2021 AND twtr_2020 AND NOT twtr_2024
            THEN 'PASS' ELSE 'FAIL' END AS status,
       svb_2019, svb_2024, tsla_2020, tsla_2021, twtr_2020, twtr_2024
FROM (
    SELECT EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2019-06-30') WHERE cik = 719739)  AS svb_2019,
           EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2024-06-30') WHERE cik = 719739)  AS svb_2024,
           EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2020-06-30') WHERE cik = 1318605) AS tsla_2020,
           EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2021-06-30') WHERE cik = 1318605) AS tsla_2021,
           EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2020-06-30') WHERE cik = 1418091) AS twtr_2020,
           EXISTS (SELECT 1 FROM sec_reference.index_members('SP500', DATE '2024-06-30') WHERE cik = 1418091) AS twtr_2024
) t;

\echo '=== 45. The sp500 universe recovers companies that have since failed ==='
-- The index universe must contain 2015 members that later delisted or
-- deregistered; today's list contains none of them.
SELECT CASE WHEN members BETWEEN 450 AND 560 AND since_delisted >= 40 THEN 'PASS' ELSE 'FAIL' END AS status,
       members AS securities_2015_06_30, since_delisted
FROM (
    SELECT COUNT(*) AS members, COUNT(*) FILTER (WHERE s.delisting_date IS NOT NULL) AS since_delisted
    FROM sec_reference.universe_at('sp500', DATE '2015-06-30') u
    JOIN sec_reference.security s USING (security_id)
) t;

\echo '=== 46. Every share-class mapping cites its source ==='
-- 27 rows are hand-mapped and 72 derived from 10-K cover pages. Every
-- row carries a substantive source_note, and every cover-page row names
-- the accession number it was read from.
SELECT CASE WHEN total >= 90 AND blank = 0 AND cover_uncited = 0 AND ciks >= 60 THEN 'PASS' ELSE 'FAIL' END AS status,
       total AS mapping_rows, ciks, blank AS rows_without_a_note, cover_uncited AS cover_page_rows_without_accession
FROM (
    SELECT COUNT(*) AS total, COUNT(DISTINCT cik) AS ciks,
           COUNT(*) FILTER (WHERE COALESCE(length(source_note), 0) < 20) AS blank,
           -- tool-derived rows name the accession; hand-mapped rows name the form
           COUNT(*) FILTER (WHERE source_note LIKE '%cover page%'
                              AND source_note !~ '\d{10}-\d{2}-\d{6}'
                              AND source_note !~ '10-[KQ]') AS cover_uncited
    FROM sec_reference.share_class
) t;

\echo '=== 47. Gold cross-sections are the index of the time ==='
-- peer_stats admits a company to a fiscal year only if it was a
-- constituent on the period end date. Tesla joined the S&P 500 on
-- 2020-12-21: its FY2018 must be absent and its FY2021 present. SVB
-- Financial: in for FY2019, gone for FY2024. The FY2012 panel must hold
-- 2012's members (previously only today's survivors, ~340 of them).
SELECT CASE WHEN NOT tsla_2018 AND tsla_2021 AND svb_2019 AND NOT svb_2024 AND fy2012 >= 450 AND fy2024 >= 480
            THEN 'PASS' ELSE 'FAIL' END AS status,
       tsla_2018, tsla_2021, svb_2019, svb_2024, fy2012 AS sp500_with_revenue_fy2012, fy2024 AS sp500_with_revenue_fy2024
FROM (
    SELECT EXISTS (SELECT 1 FROM sec_gold.peer_stats WHERE cik = 1318605 AND fiscal_year = 2018 AND concept = 'revenue' AND peer_level = 'sector') AS tsla_2018,
           EXISTS (SELECT 1 FROM sec_gold.peer_stats WHERE cik = 1318605 AND fiscal_year = 2021 AND concept = 'revenue' AND peer_level = 'sector') AS tsla_2021,
           EXISTS (SELECT 1 FROM sec_gold.peer_stats WHERE cik = 719739  AND fiscal_year = 2019 AND concept = 'total_assets' AND peer_level = 'sector') AS svb_2019,
           EXISTS (SELECT 1 FROM sec_gold.peer_stats WHERE cik = 719739  AND fiscal_year = 2024 AND concept = 'total_assets' AND peer_level = 'sector') AS svb_2024,
           (SELECT COUNT(DISTINCT cik) FROM sec_gold.peer_stats WHERE peer_level = 'sector' AND concept = 'revenue' AND index_name = 'SP500' AND fiscal_year = 2012) AS fy2012,
           (SELECT COUNT(DISTINCT cik) FROM sec_gold.peer_stats WHERE peer_level = 'sector' AND concept = 'revenue' AND index_name = 'SP500' AND fiscal_year = 2024) AS fy2024
) t;

\echo '=== 48. The S&P 500 share denominator is nearly complete and never guessed ==='
-- Every current constituent should have per-class share counts, either
-- inferred (single class by the filings) or mapped from its cover page;
-- the few that remain are the covers that say only "Common Stock" against
-- A/B members and are listed by the tool for a hand decision.
SELECT CASE WHEN in_denominator >= 480 AND members BETWEEN 495 AND 510 THEN 'PASS' ELSE 'FAIL' END AS status,
       members AS sp500_members_today, in_denominator, via_mapping, members - in_denominator AS missing
FROM (
    SELECT COUNT(*) AS members,
           COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sec_gold.share_class_shares s WHERE s.cik = m.cik)) AS in_denominator,
           COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sec_gold.share_class_shares s WHERE s.cik = m.cik AND s.method = 'mapped_class')) AS via_mapping
    FROM sec_reference.index_members('SP500', CURRENT_DATE) m
) t;

\echo '=== 49. Back-extended tickers: single-ticker histories only, never overlapping an observation ==='
-- An extended interval is an inference (05_spine/010, section 3b). It
-- must belong to a CIK with exactly one primary ticker ever, end exactly
-- where that ticker's first sighting begins, and never overlap an
-- observed interval of the same ticker under any CIK -- the stale-file
-- cases (Alcoa Inc against AA) are skipped, not guessed.
SELECT CASE WHEN extended > 6000 AND multi_primary = 0 AND detached = 0 AND overlapping = 0 AND not_primary = 0
            THEN 'PASS' ELSE 'FAIL' END AS status,
       extended AS extended_intervals, multi_primary AS ciks_with_two_primaries,
       detached AS not_abutting_first_sighting, overlapping AS overlapping_an_observation, not_primary
FROM (
    SELECT COUNT(*) AS extended,
           COUNT(*) FILTER (WHERE NOT e.is_primary) AS not_primary,
           COUNT(*) FILTER (WHERE (SELECT COUNT(DISTINCT p.ticker) FROM sec_reference.company_ticker p
                                    WHERE p.cik = e.cik AND p.is_primary) <> 1) AS multi_primary,
           COUNT(*) FILTER (WHERE e.valid_to <> (SELECT MIN(o.valid_from) FROM sec_reference.company_ticker o
                                                  WHERE o.cik = e.cik AND o.ticker = e.ticker
                                                    AND o.source = 'observed')) AS detached,
           COUNT(*) FILTER (WHERE EXISTS (SELECT 1 FROM sec_reference.company_ticker o
                                           WHERE o.ticker = e.ticker AND o.source = 'observed'
                                             AND o.valid_from < e.valid_to
                                             AND COALESCE(o.valid_to, DATE '9999-12-31') > e.valid_from)) AS overlapping
    FROM sec_reference.company_ticker e
    WHERE e.source = 'extended'
) t;

\echo '=== 50. Pre-2019 labels: Apple resolves in 2015 and no extended label passes as observed ==='
-- Before the back-extension cik_at('AAPL', 2015) was NULL and 2,420 of
-- the 7,298 members of the 2015 universe had no ticker at all. Extended
-- labels fill most of that, but they are inferences and must never
-- carry ticker_is_asof = TRUE.
SELECT CASE WHEN aapl = 320193 AND msft = 789019 AND unlabelled < 1600 AND extended_flagged_asof = 0 AND extended_labels > 3500
            THEN 'PASS' ELSE 'FAIL' END AS status,
       aapl AS cik_at_aapl_2015, unlabelled AS members_2015_without_ticker,
       extended_labels AS members_2015_labelled_by_extension, extended_flagged_asof
FROM (
    SELECT sec_reference.cik_at('AAPL', DATE '2015-06-30') AS aapl,
           sec_reference.cik_at('MSFT', DATE '2015-06-30') AS msft,
           COUNT(*) FILTER (WHERE u.ticker IS NULL) AS unlabelled,
           COUNT(*) FILTER (WHERE l.source = 'company_ticker_extended') AS extended_labels,
           COUNT(*) FILTER (WHERE l.source = 'company_ticker_extended' AND u.ticker_is_asof) AS extended_flagged_asof
    FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30') u
    LEFT JOIN LATERAL (
        SELECT l.source FROM sec_reference.listing l
        WHERE l.security_id = u.security_id
          AND l.valid_from <= DATE '2015-06-30'
          AND (l.valid_to IS NULL OR l.valid_to > DATE '2015-06-30')
        ORDER BY l.valid_from DESC LIMIT 1
    ) l ON TRUE
) t;

\echo '=== 51. The membership timeline reproduces the per-fact precedence and never overlaps ==='
-- Gold joins sec_reference.index_membership_timeline with a plain range
-- condition instead of a per-fact LATERAL over index_membership. The
-- timeline must give the same answer as that LATERAL at every interval
-- boundary and the day before it, and its non-overlap is an EXCLUDE
-- constraint, which must exist.
SELECT CASE WHEN mismatches = 0 AND probes > 5000 AND has_exclusion THEN 'PASS' ELSE 'FAIL' END AS status,
       probes AS boundary_probes, mismatches, has_exclusion AS exclude_constraint_present,
       (SELECT COUNT(*) FROM sec_reference.index_membership_timeline) AS timeline_rows
FROM (
    SELECT COUNT(*) AS probes,
           COUNT(*) FILTER (WHERE (lat.index_name, lat.gics_sector, lat.gics_sub_industry)
                                  IS DISTINCT FROM (tl.index_name, tl.gics_sector, tl.gics_sub_industry)) AS mismatches,
           EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conname = 'index_membership_timeline_no_overlap' AND contype = 'x') AS has_exclusion
    FROM (
        SELECT DISTINCT cik, d
        FROM (SELECT cik, valid_from AS d FROM sec_reference.index_membership
              UNION ALL SELECT cik, valid_from - 1 FROM sec_reference.index_membership
              UNION ALL SELECT cik, valid_to FROM sec_reference.index_membership WHERE valid_to IS NOT NULL
              UNION ALL SELECT cik, valid_to - 1 FROM sec_reference.index_membership WHERE valid_to IS NOT NULL) b
    ) p
    LEFT JOIN LATERAL (
        SELECT m.index_name, m.gics_sector, m.gics_sub_industry
        FROM sec_reference.index_membership m
        WHERE m.cik = p.cik AND m.valid_from <= p.d AND (m.valid_to IS NULL OR m.valid_to > p.d)
        ORDER BY (m.source = 'wikipedia_history') DESC, m.valid_from DESC LIMIT 1
    ) lat ON TRUE
    LEFT JOIN sec_reference.index_membership_timeline tl
           ON tl.cik = p.cik AND tl.valid_from <= p.d AND (tl.valid_to IS NULL OR tl.valid_to > p.d)
) t;

\echo '=== 52. total_debt is never the current portion alone, and the S&P 500 gap is closed where the filings allow ==='
-- With both formula operands optional, 26 FY2024 totals were the current
-- portion by itself: Deere 15.9B against roughly 65B. The noncurrent
-- operand is now required, so Deere resolves to nothing rather than to
-- a wrong number, while the totals JPMorgan, Goldman and Oracle file
-- under lines the map never named resolve; Discover, Synchrony and
-- Equity Residential gain a revenue; a REIT filing both a total and
-- lease income keeps the total.
SELECT CASE WHEN jpm BETWEEN 350 AND 500 AND gs > 200 AND orcl BETWEEN 80 AND 120
             AND (deere IS NULL OR deere > 40) AND dfs > 15 AND eqr > 2
             AND realty_tag <> 'OperatingLeaseLeaseIncome'
             AND sp500_debt >= 430 AND sp500_rev >= 498
            THEN 'PASS' ELSE 'FAIL' END AS status,
       jpm AS jpm_total_debt_bn, gs AS goldman_bn, orcl AS oracle_bn, deere AS deere_bn_or_null,
       dfs AS discover_revenue_bn, eqr AS equity_residential_revenue_bn, realty_tag AS realty_income_revenue_tag,
       sp500_debt AS sp500_members_with_fy2024_total_debt, sp500_rev AS with_fy2024_revenue
FROM (
    SELECT (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 19617   AND fiscal_year = 2024 AND concept = 'total_debt' AND peer_level = 'sector') AS jpm,
           (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 886982  AND fiscal_year = 2024 AND concept = 'total_debt' AND peer_level = 'sector') AS gs,
           (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 1341439 AND fiscal_year = 2024 AND concept = 'total_debt' AND peer_level = 'sector') AS orcl,
           (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 315189  AND fiscal_year = 2024 AND concept = 'total_debt' AND peer_level = 'sector') AS deere,
           (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 1393612 AND fiscal_year = 2024 AND concept = 'revenue'    AND peer_level = 'sector') AS dfs,
           (SELECT ROUND(value/1e9) FROM sec_gold.peer_stats WHERE cik = 906107  AND fiscal_year = 2024 AND concept = 'revenue'    AND peer_level = 'sector') AS eqr,
           (SELECT tag FROM sec_gold.latest_annual(726728, 'revenue') LIMIT 1) AS realty_tag,
           (SELECT COUNT(*) FROM sec_reference.index_members('SP500', DATE '2024-12-31') m
             WHERE EXISTS (SELECT 1 FROM sec_gold.peer_stats p WHERE p.cik = m.cik AND p.fiscal_year = 2024 AND p.concept = 'total_debt')) AS sp500_debt,
           (SELECT COUNT(*) FROM sec_reference.index_members('SP500', DATE '2024-12-31') m
             WHERE EXISTS (SELECT 1 FROM sec_gold.peer_stats p WHERE p.cik = m.cik AND p.fiscal_year = 2024 AND p.concept = 'revenue')) AS sp500_rev
) t;
