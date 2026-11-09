-- Share counts, resolved through a priority ladder with share-class
-- summation.
--
-- Why this needs its own function rather than a concept_tag_map row:
-- concept_tag_map resolves one tag to one row, and the whole point here
-- is that a large minority of companies never publish a consolidated
-- share count. They tag only per share class, and the consolidated-only
-- filter used everywhere else in gold throws those rows away.
--
-- Measured coverage of the tracked universe for periods since 2024:
--
--   CommonStockSharesOutstanding, consolidated only     1,037   69.2%
--   plus summing across the share-class axis            1,167   77.9%
--   all five tags, class-summed, treasury excluded      1,490   99.5%
--
-- So the gap was never missing data. It was a tag choice plus a blanket
-- `segments IS NULL` filter.
--
-- Two traps this avoids:
--
-- 1. The largest segmented bucket is EquityComponents=CommonStock at
--    245,447 rows, which is the equity roll-forward dimension, not a
--    share class. Summing over every segment would double count.
--    Only ClassOfStock axes are summed, and treasury lines excluded.
--
-- 2. A company that publishes BOTH a consolidated total and per-class
--    rows must not have them added together. Alphabet reports 12.211B
--    consolidated alongside its class rows. The ladder therefore takes
--    the consolidated figure when present and only falls through to
--    summation when it is absent.
--
-- The weighted-average diluted count is a period average, not a
-- point-in-time count. It sits last and is reported with its source so
-- a caller can see when it was used rather than silently blending it
-- with instant counts.
--
-- RECENCY VERSUS KIND. The ladder used to order by value_date first and
-- rung second, so a period average with a newer period end beat a real
-- point-in-time count from the quarter before. Measured 2026-09-04:
-- 216 of 1,569 tracked companies resolved to a WeightedAverage* tag as
-- of today, and for 87 of them an instant count within 400 days
-- existed. Now an instant count within 400 days of the newest available
-- period beats an average at the newest period; only when no instant
-- count is that recent does the average win, and `source_tag` says so.

-- SCALE. Filers mis-scale share counts the way they mis-scale balance
-- sheets: Reinsurance Group of America's 10-Qs carry
-- CommonStockSharesIssued of 85,310,598,000,000 against 85,310,598 on
-- its 10-Ks, a million-fold, from 2023 on; Horace Mann's 10-Ks carry
-- each weighted average twice, once in shares and once a thousand-fold
-- too large. Read as-is the first put a $17 quadrillion market cap at
-- the top of every cap-weighted sort it touched. The balance-sheet
-- guard (028_suspect_fact) covers dollar columns only, and a share
-- count has no column of neighbours to be compared with, so the
-- reference here is the filing's own income statement: net income
-- divided by basic earnings per share implies the share count without
-- depending on how any share tag was scaled. A candidate more than 333
-- times that implied count, or less than a 333rd of it, is refused
-- (every scale error is a thousand- or a million-fold; no real count is
-- that far from its own EPS denominator; within-filing differences
-- between issued, outstanding and the average are a factor of two or
-- three at most). Measured 2026-10-14 over the companies of the factor
-- panel: 81% of filings with a share fact have an anchor (both facts
-- present and non-zero); the rule refuses 1,812 instant counts of 276
-- companies in 657 filings and 7,024 weighted averages. A filing
-- without an anchor (Berkshire dimensions its EPS by class, so its
-- million-fold A-equivalent averages of 2011-12 had none) meets a
-- second test: a consolidated count is refused when ANY other knowable
-- filing carries the same tag within 400 days more than 333 times off
-- it. That refuses the right values beside the wrong ones (a median
-- cannot arbitrate: the mis-scaled filing's comparatives supersede the
-- right originals and outnumber them), so the ladder falls through to
-- another tag or to nothing, which is the honest outcome when a filer
-- contradicts itself a thousand-fold and no income line can settle it.
-- Only knowable facts enter either test.

-- ISSUED IS NOT OUTSTANDING. CommonStockSharesIssued counts every share
-- ever issued, treasury shares included; outstanding is issued less
-- treasury. Read as an outstanding count it put McDonald's at 1,660.6M
-- shares on every date from 2009 to 2026 (outstanding ~715M; 945M sit
-- in treasury), a market cap 2.3 times too large, and Exxon Mobil at
-- 8,019M through 2013-2015, when its 10-Qs tagged issued and treasury
-- but not outstanding. Measured 2026-11-09 over the S&P 1500 members
-- of 2014-06-30, 2020-06-30 and 2026-06-30: the rung resolved 296, 354
-- and 324 members, and 59, 92 and 87 of them read more than 30% above
-- the weighted-average basic count of their own latest period. So the
-- rung now subtracts the treasury shares (TreasuryStockCommonShares, or
-- its pre-2023 name TreasuryStockShares) the filer reports at the same
-- balance-sheet date, undimensioned, and says so in `method`
-- ('issued_less_treasury'). A filer that holds no treasury stock, or
-- retires what it buys, reports none, and its issued count, which is
-- then its outstanding count, is unchanged.

-- Explicit drop: CREATE OR REPLACE cannot change a RETURNS TABLE
-- shape, so editing this signature and re-applying the single file
-- against a live schema fails with "cannot change return type of
-- existing function". A full build-gold drops the schema first and
-- would not notice; the iteration loop does.
DROP FUNCTION IF EXISTS sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER);

CREATE OR REPLACE FUNCTION sec_gold.shares_outstanding_at(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    shares         NUMERIC,
    value_date     DATE,
    tradable_from  DATE,
    source_tag     TEXT,
    method         TEXT
)
LANGUAGE sql STABLE AS $$
    WITH k AS (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d),
    -- Every share-count fact knowable as of the date, including the
    -- per-class rows that the consolidated filter normally discards.
    visible AS (
        SELECT n.tag, n.value, n.value_date, n.tradable_from, n.segments, n.qtrs, n.adsh
        FROM sec_silver.num_silver n, k
        WHERE n.cik = p_cik
          AND n.coreg IS NULL
          AND n.value IS NOT NULL
          AND n.uom = 'shares'
          AND n.tag IN (
              'EntityCommonStockSharesOutstanding',
              'CommonStockSharesOutstanding',
              'CommonStockSharesIssued',
              'WeightedAverageNumberOfDilutedSharesOutstanding',
              'WeightedAverageNumberOfSharesOutstandingBasic'
          )
          AND n.tradable_from <= k.d
          AND (n.superseded_tradable > k.d OR n.superseded_tradable IS NULL)
    ),
    -- Treasury shares at a balance-sheet date, knowable as of the date:
    -- subtracted from an issued count. Kept out of `visible` so a
    -- treasury fact can never itself become a share-count candidate. ABS
    -- because the sign convention for a contra-equity count is the
    -- filer's. The us-gaap names in priority order: the common-only
    -- balance (TreasuryStockCommonShares since 2023, TreasuryStockShares
    -- before, TreasuryStockNumberOfSharesHeld before that), then the
    -- common-and-preferred balance (Wells Fargo's only tag). The balance
    -- sheet's undimensioned figure first; the equity statement's treasury
    -- column second, by its two standard members only (TreasuryStockCommon,
    -- 1,075 filers; TreasuryStock, 415), because McKesson, Dell and Monro
    -- carry the count nowhere else on some dates.
    treasury AS (
        SELECT n.adsh, n.value_date, n.tradable_from, ABS(n.value) AS treasury,
               CASE n.tag WHEN 'TreasuryStockCommonShares'             THEN 1
                          WHEN 'TreasuryStockShares'                   THEN 2
                          WHEN 'TreasuryStockNumberOfSharesHeld'       THEN 3
                          ELSE 4 END AS tag_rank,
               (n.segments IS NOT NULL)::INTEGER AS dim_rank
        FROM sec_silver.num_silver n, k
        WHERE n.cik = p_cik
          AND n.coreg IS NULL
          AND (n.segments IS NULL
               OR n.segments IN ('EquityComponents=TreasuryStockCommon;', 'EquityComponents=TreasuryStock;'))
          AND n.value IS NOT NULL
          AND n.uom = 'shares'
          AND n.tag IN ('TreasuryStockCommonShares', 'TreasuryStockShares',
                        'TreasuryStockNumberOfSharesHeld', 'TreasuryStockCommonAndPreferredShares')
          AND n.tradable_from <= k.d
          AND (n.superseded_tradable > k.d OR n.superseded_tradable IS NULL)
    ),
    -- The filing's own share count implied by its income statement: net
    -- income over basic EPS at the longest period of the latest period
    -- end the filing reports, knowable with the filing. The income line
    -- is the first the filing carries of NetIncomeLoss, the amount
    -- available to common, ProfitLoss and continuing operations (PG&E
    -- files only the second and third); the per-share line the first of
    -- basic, basic-and-diluted, continuing-operations basic and diluted.
    -- Only undimensioned facts: an issuer whose EPS is per one class
    -- (Berkshire, per Class A) dimensions it and so has no anchor here,
    -- which is right, since its summed count is in another class's units.
    anchor AS (
        SELECT DISTINCT ON (adsh) adsh, ni / eps AS implied
        FROM (
            SELECT n.adsh, n.value_date, n.qtrs,
                   COALESCE(MAX(n.value) FILTER (WHERE n.tag = 'NetIncomeLoss'),
                            MAX(n.value) FILTER (WHERE n.tag = 'NetIncomeLossAvailableToCommonStockholdersBasic'),
                            MAX(n.value) FILTER (WHERE n.tag = 'ProfitLoss'),
                            MAX(n.value) FILTER (WHERE n.tag = 'IncomeLossFromContinuingOperations')) AS ni,
                   COALESCE(MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareBasic'),
                            MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareBasicAndDiluted'),
                            MAX(n.value) FILTER (WHERE n.tag = 'IncomeLossFromContinuingOperationsPerBasicShare'),
                            MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareDiluted')) AS eps
            FROM sec_silver.num_silver n, k
            WHERE n.cik = p_cik
              AND n.coreg IS NULL AND n.segments IS NULL AND n.value IS NOT NULL
              AND n.tag IN ('NetIncomeLoss', 'NetIncomeLossAvailableToCommonStockholdersBasic', 'ProfitLoss',
                            'IncomeLossFromContinuingOperations',
                            'EarningsPerShareBasic', 'EarningsPerShareBasicAndDiluted',
                            'IncomeLossFromContinuingOperationsPerBasicShare', 'EarningsPerShareDiluted')
              AND n.tradable_from <= k.d
              AND n.adsh IN (SELECT adsh FROM visible)
            GROUP BY n.adsh, n.value_date, n.qtrs
        ) f
        WHERE ni IS NOT NULL AND eps IS NOT NULL AND ni <> 0 AND ABS(eps) >= 0.01
        ORDER BY adsh, qtrs DESC, value_date DESC
    ),
    -- AS-CONVERTED BY EPS (sec_reference.share_class.as_converted_eps).
    -- For an issuer whose other classes and participating preferred
    -- convert into its listed class at rates that move (Visa), the
    -- filing's net income over the listed class's basic EPS is the whole
    -- company in that class's units, and that is the count: Visa's is
    -- within 1% of its own diluted as-converted Class A count at every
    -- half-year 2010-2026, 1.11 to 1.58 times its Class A alone. The
    -- latest period end of each filing and its SHORTEST period, the
    -- nearest to a point in time. Not the class's instant count times
    -- the period's ratio: when the class mix moves inside the period the
    -- two disagree (Visa's 2024 exchange offer and Class C sales lifted
    -- Class A from 1,574M to 1,733M in a year; instant times the annual
    -- ratio read 6.8% high). Net income, else ProfitLoss (Visa's tag
    -- from FY2019). The count must lie between 1 and 10 times the
    -- class's own basic weighted average: the listed class cannot be
    -- more than the company, and a near-zero EPS makes the ratio noise.
    as_converted AS (
        SELECT DISTINCT ON (f.adsh) f.adsh, f.ni / f.eps AS a_equiv
        FROM (
            SELECT n.adsh, n.value_date, n.qtrs,
                   COALESCE(MAX(n.value) FILTER (WHERE n.tag = 'NetIncomeLoss' AND n.segments IS NULL),
                            MAX(n.value) FILTER (WHERE n.tag = 'ProfitLoss' AND n.segments IS NULL)) AS ni,
                   MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareBasic'
                                          AND n.segments = 'ClassOfStock=' || sc.class_label || ';') AS eps,
                   MAX(n.value) FILTER (WHERE n.tag = 'WeightedAverageNumberOfSharesOutstandingBasic'
                                          AND n.segments = 'ClassOfStock=' || sc.class_label || ';') AS wa
            FROM sec_reference.share_class sc
            JOIN sec_silver.num_silver n ON n.cik = sc.cik, k
            WHERE sc.cik = p_cik AND sc.as_converted_eps
              AND n.coreg IS NULL AND n.value IS NOT NULL AND n.qtrs > 0
              AND n.tag IN ('NetIncomeLoss', 'ProfitLoss', 'EarningsPerShareBasic',
                            'WeightedAverageNumberOfSharesOutstandingBasic')
              AND (n.segments IS NULL OR n.segments = 'ClassOfStock=' || sc.class_label || ';')
              AND n.value_date >= sc.effective_from
              AND (sc.effective_to IS NULL OR n.value_date < sc.effective_to)
              AND n.tradable_from <= k.d
              AND n.adsh IN (SELECT adsh FROM visible)
            GROUP BY n.adsh, n.value_date, n.qtrs, sc.class_label
        ) f
        WHERE f.ni IS NOT NULL AND f.eps IS NOT NULL AND f.wa > 0 AND f.ni <> 0 AND ABS(f.eps) >= 0.01
          AND f.ni / f.eps / f.wa BETWEEN 1 AND 10
        ORDER BY f.adsh, f.value_date DESC, f.qtrs ASC
    ),
    consolidated AS (
        SELECT v.value AS shares, v.value_date, v.tradable_from, v.tag AS source_tag,
               'consolidated'::TEXT AS method,
               CASE v.tag
                   WHEN 'EntityCommonStockSharesOutstanding'            THEN 1
                   WHEN 'CommonStockSharesOutstanding'                  THEN 2
                   WHEN 'CommonStockSharesIssued'                       THEN 3
                   WHEN 'WeightedAverageNumberOfDilutedSharesOutstanding' THEN 8
                   ELSE 9
               END AS rung,
               v.qtrs, a.implied,
               EXISTS (SELECT 1 FROM visible o
                        WHERE v.value > 0 AND o.segments IS NULL AND o.tag = v.tag AND o.adsh <> v.adsh AND o.value > 0
                          AND o.value_date BETWEEN v.value_date - 400 AND v.value_date + 400
                          AND (v.value / o.value >= 333 OR o.value / v.value >= 333)) AS same_tag_far,
               v.adsh, FALSE AS as_converted
        FROM visible v LEFT JOIN anchor a ON a.adsh = v.adsh
        WHERE v.segments IS NULL
    ),
    -- Sum the share classes only where no consolidated row exists for
    -- that tag and period.
    --
    -- THE EQUIVALENT TRAP. Summing assumes the class rows are disjoint
    -- parts of one whole. For a handful of issuers they are not: they
    -- publish the SAME total twice, converted into each class's units.
    -- Berkshire is the case that exposed it:
    --
    --   ClassOfStock=EquivalentClassA        1,438,223
    --   ClassOfStock=EquivalentClassB    2,157,335,139
    --   ratio exactly 1500.0  (BRK.A converts to 1,500 BRK.B)
    --
    -- Adding those double counts the entire company. The error happened
    -- to be only 0.067% because A shares are tiny expressed in B units,
    -- which is precisely why it went unnoticed: it looked plausible and
    -- was wrong in principle. The A-equivalent row is now is_excluded in
    -- the mapping, so it never reaches the sum.
    by_class AS (
        SELECT
            -- Plain SUM is safe: only mapped classes reach here, and
            -- Berkshire's duplicate A-equivalent expression is marked
            -- is_excluded in the mapping rather than being detected by
            -- string matching.
            SUM(v.value) AS shares,
            v.value_date,
            MAX(v.tradable_from) AS tradable_from, v.tag AS source_tag,
            'class_sum_mapped'::TEXT AS method,
            CASE v.tag
                WHEN 'CommonStockSharesOutstanding' THEN 4
                WHEN 'CommonStockSharesIssued'      THEN 5
                ELSE 9
            END AS rung,
            v.qtrs, MAX(a.implied) AS implied, FALSE AS same_tag_far,
            MAX(v.adsh) AS adsh,
            BOOL_OR(sc.as_converted_eps) AS as_converted
        FROM visible v LEFT JOIN anchor a ON a.adsh = v.adsh
        -- ALLOWLIST, not a pattern match. The previous filter was
        -- `segments LIKE 'ClassOfStock=%' AND NOT ILIKE '%treasury%'`,
        -- which had two defects found by testing rather than reading:
        --
        --   1. It matched ClassOfStock=SeriesAPreferredStock (97 issuers)
        --      and rows carrying a second axis such as
        --      SubsequentEventType or RelatedPartyTransaction (966
        --      issuers), summing non-common and non-class rows into a
        --      common share count. 78 tracked issuers were exposed.
        --   2. More fundamentally, summing class members is wrong in
        --      general: against issuers publishing both a consolidated
        --      total and clean per-class rows, the sum disagreed with the
        --      total in 312 of 1,033 cases, because the axis contains
        --      aggregates, subsets and duplicates of its own members.
        --
        -- No regex fixes (2). So the fallback sums only classes that
        -- sec_reference.share_class explicitly maps. Where an issuer has
        -- unmapped classes it yields nothing and the ladder falls back to
        -- a consolidated figure, which is the honest outcome.
        --
        -- sec_gold.share_class_shares is the correct object for anything
        -- needing per-class detail; this stays a single-number
        -- convenience.
        JOIN sec_reference.share_class sc
          ON sc.cik = p_cik
         AND v.segments = 'ClassOfStock=' || sc.class_label || ';'
         AND NOT sc.is_excluded
         AND v.value_date >= sc.effective_from
         AND (sc.effective_to IS NULL OR v.value_date < sc.effective_to)
        WHERE NOT EXISTS (
              SELECT 1 FROM consolidated c
              WHERE c.source_tag = v.tag AND c.value_date = v.value_date
          )
        -- One sum per period length. A second- or third-quarter 10-Q
        -- reports the weighted average for the quarter AND for the year
        -- to date at the same period end; grouping without qtrs added the
        -- two, and Berkshire's 2026-06-30 10-Q read 4.311B (2,154,664,073
        -- for the quarter plus 2,155,918,015 for six months) instead of
        -- 2.155B. The ladder then takes the shortest period.
        GROUP BY v.value_date, v.tag, v.qtrs
    ),
    -- An issued count, consolidated or summed over mapped classes, has
    -- the treasury taken from it: the same balance-sheet date first, else
    -- the newest within 400 days before it (Deere reports treasury shares
    -- in its 10-K only, so its 10-Q issued counts take the last fiscal
    -- year end's; buybacks since then leave the net slightly high, never
    -- doubled); the balance sheet's figure before the equity statement's;
    -- then the same filing, the tag priority (which settles the 2023
    -- rename's overlap, where a filer briefly carried both names with one
    -- value) and the newest knowable report.
    --
    -- NET, OR ALREADY NET. Some filers tag a count that is already net
    -- of treasury as issued: PepsiCo's balance sheet reads "issued, net
    -- of repurchased common stock at par value: 1,368 shares" beside
    -- 499M repurchased, so subtracting again gives 869M against a basic
    -- average of 1,367M; Disney's issued count is rounded to "1.8
    -- billion". The filing's own income statement arbitrates: the
    -- treasury is subtracted only when the net count is at least as close
    -- as the gross count to its net income over basic EPS (or, without
    -- that anchor, to its basic weighted average). With neither, the
    -- issued count stands, as it did before. Measured 2026-11-09 on the
    -- members of three dates: 567 of 594 unrefereed subtractions moved
    -- toward the filer's own average; the 27 that moved away are the
    -- cases this test refuses.
    netted AS (
        SELECT CASE WHEN c.as_converted THEN ac.a_equiv
                    ELSE c.shares - COALESCE(t.treasury, 0) END AS shares,
               c.value_date, c.tradable_from, c.source_tag,
               CASE WHEN c.as_converted               THEN 'class_sum_as_converted'
                    WHEN t.treasury IS NULL           THEN c.method
                    WHEN c.method = 'consolidated'    THEN 'issued_less_treasury'
                    ELSE 'class_sum_less_treasury' END AS method,
               c.rung, c.qtrs, c.implied, c.same_tag_far, c.shares AS gross_shares
        FROM (
            SELECT * FROM consolidated
            UNION ALL
            SELECT * FROM by_class
        ) c
        -- A flagged issuer's count is the as-converted count of the
        -- filing its class count came from, dated at that count's period
        -- end. Without one it yields nothing rather than the listed class
        -- alone, the plausible wrong answer (Visa's Class A was 63-87% of
        -- the company); and its class-dimensioned weighted averages are
        -- not candidates, since Visa's diluted Class A average is already
        -- as-converted and its basic one is not.
        LEFT JOIN as_converted ac ON c.as_converted AND ac.adsh = c.adsh
        LEFT JOIN LATERAL (
            SELECT tr.treasury FROM treasury tr
            WHERE c.source_tag = 'CommonStockSharesIssued'
              AND tr.value_date BETWEEN c.value_date - 400 AND c.value_date
              AND tr.treasury > 0 AND tr.treasury < c.shares
            ORDER BY tr.value_date DESC, tr.dim_rank, (tr.adsh = c.adsh) DESC, tr.tag_rank, tr.tradable_from DESC
            LIMIT 1
        ) t0 ON TRUE
        -- The referee when the filing has no income anchor: its own basic
        -- weighted average, the shortest period at its latest end.
        LEFT JOIN LATERAL (
            SELECT w.value AS basic FROM visible w
            WHERE t0.treasury IS NOT NULL AND c.implied IS NULL
              AND w.adsh = c.adsh AND w.segments IS NULL AND w.value > 0
              AND w.tag = 'WeightedAverageNumberOfSharesOutstandingBasic'
            ORDER BY w.value_date DESC, w.qtrs ASC
            LIMIT 1
        ) wb ON TRUE
        -- Nested CASE, not AND: Postgres does not promise to evaluate AND
        -- left to right, and LN must never see a non-positive value.
        CROSS JOIN LATERAL (
            SELECT CASE WHEN t0.treasury IS NULL OR COALESCE(c.implied, wb.basic) IS NULL
                          OR COALESCE(c.implied, wb.basic) = 0 THEN NULL
                        WHEN ABS(LN((c.shares - t0.treasury) / ABS(COALESCE(c.implied, wb.basic))))
                             <= ABS(LN(c.shares / ABS(COALESCE(c.implied, wb.basic))))
                        THEN t0.treasury END AS treasury
        ) t
        WHERE NOT c.as_converted
           OR (ac.a_equiv IS NOT NULL AND c.source_tag NOT LIKE 'WeightedAverage%')
    ),
    laddered AS (
        SELECT l.*, MAX(l.value_date) OVER () AS newest_period
        FROM netted l
        WHERE l.shares > 0
          -- The scale guard: nothing over a count a thousand-fold off
          -- its own filing's net income over EPS; without that anchor,
          -- nothing over a tag the company's nearby filings contradict.
          -- The count as filed must pass as well as the count net of
          -- treasury: a subtraction never rescues a mis-scaled figure.
          -- W. R. Berkley's 2012 10-Qs tag issued (137,167,115,000) and
          -- treasury (97,950,803,000) both a thousand-fold large; the
          -- difference sits 284 times its EPS count, inside the band, and
          -- had read as a $1.5 trillion company for twelve months until
          -- the gross figure was tested too (found 2026-11-09).
          AND CASE WHEN l.implied IS NOT NULL
                   THEN ABS(l.shares / l.implied) BETWEEN 1.0 / 333 AND 333
                    AND ABS(l.gross_shares / l.implied) BETWEEN 1.0 / 333 AND 333
                   ELSE NOT l.same_tag_far END
    )
    SELECT shares, value_date, tradable_from, source_tag, method
    FROM laddered
    -- An instant count (rungs 1-5) within 400 days of the newest period
    -- first; then the most recent period, the most trustworthy rung, and
    -- the shortest period for an average (qtrs 1 is closer to a point in
    -- time than qtrs 4).
    ORDER BY (rung <= 5 AND value_date >= newest_period - 400) DESC,
             value_date DESC,
             rung ASC,
             qtrs ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER) IS
    'Share count knowable on p_asof, by priority ladder with mapped '
    'share-class summation. method: consolidated | issued_less_treasury | '
    'class_sum_mapped | class_sum_less_treasury | class_sum_as_converted; an '
    'issued count has the treasury shares of the same balance-sheet date '
    'subtracted; an issuer flagged as_converted_eps in share_class is the '
    'filing''s net income over its listed class''s basic EPS, the company '
    'in that class''s units (Visa). '
    'A count more than 333 times, or less than a 333rd of, the filing''s '
    'own net income over basic EPS is refused as mis-scaled; without that '
    'anchor, a count contradicted that far by the same tag in another '
    'filing within 400 days is refused. '
    'An instant count within 400 days of the newest period beats a '
    'weighted average. NOT sufficient for market cap on multi-class '
    'issuers - that needs each class priced separately (177 of 1,569 '
    'tracked companies hold more than one listed ticker, 2026-09-04); '
    'use share_classes_at.';
