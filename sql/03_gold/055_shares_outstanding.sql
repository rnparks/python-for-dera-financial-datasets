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
-- without an anchor (Berkshire's million-fold A-equivalent averages of
-- 2011-12 had none until its per-unit EPS, tagged by class, was read as
-- the anchor through sec_reference.share_unit) meets a second test: a consolidated count is refused when ANY other knowable
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
    -- WHOLE-COMPANY UNITS (sec_reference.share_unit). Berkshire states
    -- its weighted averages and EPS per equivalent Class A share, both
    -- classes together, undimensioned until 2015 and as
    -- ClassOfStock=CommonClassA in 2016-2017; one unit is 1,500 BRK-B
    -- (30 before the 2010-01-21 B split). Read as shares and priced at
    -- BRK-B the company was 1/1,500 of itself from 2010 to 2017. Inside
    -- a row's filing window such a count is the whole company and is
    -- multiplied into BRK-B shares; the issuer's other undimensioned
    -- counts there are dropped (its undimensioned cover count is its
    -- Class A alone).
    unit AS (
        SELECT u.unit_member, u.shares_per_unit, u.filed_from, u.filed_to
        FROM sec_reference.share_unit u
        WHERE u.cik = p_cik
    ),
    -- Every share-count fact knowable as of the date, every vintage,
    -- including the per-class rows that the consolidated filter normally
    -- discards. A class tagged as CAPITAL stock is read as common stock
    -- when it is dimensioned by class (so only a mapped class can reach a
    -- sum): Google Inc's Class C of 2014-2015 is
    -- CapitalStockSharesOutstanding, and without it Google read at half
    -- its size for 15 months. Undimensioned capital stock can include
    -- preferred and stays out.
    facts AS (
        SELECT CASE WHEN n.segments IS NOT NULL AND n.tag = 'CapitalStockSharesOutstanding' THEN 'CommonStockSharesOutstanding'
                    WHEN n.segments IS NOT NULL AND n.tag = 'CapitalStockSharesIssued' THEN 'CommonStockSharesIssued'
                    ELSE n.tag END AS tag,
               n.value * COALESCE(u.shares_per_unit, 1) AS value, n.value_date, n.tradable_from,
               CASE WHEN u.shares_per_unit IS NOT NULL THEN NULL ELSE n.segments END AS segments,
               n.qtrs, n.adsh, n.superseded_tradable,
               -- The vintage that superseded this one (silver's own order).
               LEAD(n.value * COALESCE(u.shares_per_unit, 1)) OVER w AS next_value,
               LEAD(n.adsh) OVER w AS next_adsh
        FROM sec_silver.num_silver n
        CROSS JOIN k
        LEFT JOIN unit u
          ON n.tradable_from >= u.filed_from AND (u.filed_to IS NULL OR n.tradable_from < u.filed_to)
         AND n.tag LIKE 'WeightedAverage%'
         AND (n.segments IS NULL OR n.segments = 'ClassOfStock=' || u.unit_member || ';')
        WHERE n.cik = p_cik
          AND NOT (n.segments IS NULL AND u.shares_per_unit IS NULL
                   AND EXISTS (SELECT 1 FROM unit u2
                               WHERE n.tradable_from >= u2.filed_from
                                 AND (u2.filed_to IS NULL OR n.tradable_from < u2.filed_to)))
          AND n.coreg IS NULL
          AND n.value IS NOT NULL
          AND n.uom = 'shares'
          AND (n.tag IN (
                  'EntityCommonStockSharesOutstanding',
                  'CommonStockSharesOutstanding',
                  'CommonStockSharesIssued',
                  'WeightedAverageNumberOfDilutedSharesOutstanding',
                  'WeightedAverageNumberOfSharesOutstandingBasic')
               OR (n.segments IS NOT NULL AND n.tag IN ('CapitalStockSharesOutstanding', 'CapitalStockSharesIssued')))
          AND n.tradable_from <= k.d
        WINDOW w AS (PARTITION BY n.tag, n.value_date, n.qtrs, n.segments ORDER BY n.known_at, n.adsh)
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
    -- Cover-page counts (sec_reference.cover_share_count, from SEC's XBRL
    -- frames API) knowable on the date: a referee for the balance-sheet
    -- counts below, and the last resort when there is no other count.
    cover AS (
        SELECT c.adsh, c.cover_date, c.shares, c.tradable_from
        FROM sec_reference.cover_share_count c, k
        WHERE c.cik = p_cik AND c.tradable_from <= k.d
    ),
    -- The newest share count implied by any knowable filing's income
    -- statement within about 500 days: the reference a last-resort cover
    -- count must agree with (filers mis-scale covers too: Sempra's of
    -- 2009-09-30 reads 246 trillion shares, Regency Centers' of 2011-05-04
    -- 82 billion).
    implied_any AS (
        SELECT ABS(ni.value / eps.value) AS implied
        FROM sec_silver.num_silver ni
        JOIN sec_silver.num_silver eps
          ON eps.adsh = ni.adsh AND eps.cik = ni.cik AND eps.value_date = ni.value_date
         AND eps.qtrs = ni.qtrs AND eps.tag = 'EarningsPerShareBasic'
         AND eps.segments IS NULL AND eps.coreg IS NULL AND ABS(eps.value) >= 0.01, k
        WHERE ni.cik = p_cik AND ni.tag = 'NetIncomeLoss' AND ni.segments IS NULL AND ni.coreg IS NULL
          AND ni.value <> 0 AND ni.tradable_from <= k.d AND ni.value_date >= k.d - 500
          AND (ni.superseded_tradable > k.d OR ni.superseded_tradable IS NULL)
        ORDER BY ni.value_date DESC, ni.qtrs DESC
        LIMIT 1
    ),
    -- The filing's own share count implied by its income statement: net
    -- income over basic EPS at the longest period of the latest period
    -- end the filing reports, knowable with the filing. The income line
    -- is the first the filing carries of NetIncomeLoss, the amount
    -- available to common, ProfitLoss and continuing operations (PG&E
    -- files only the second and third); the per-share line the first of
    -- basic, basic-and-diluted, continuing-operations basic and diluted.
    -- Only undimensioned facts, except inside a share_unit window, where
    -- the EPS tagged with the unit's member is the whole company's per
    -- unit too, and the implied count is converted like the counts:
    -- Berkshire's 10-Qs of 2011-2012 tag their equivalent Class A
    -- averages a million-fold large (1,650,944,000,000) and their EPS
    -- only per Class A, and without this anchor nothing refused them.
    anchor AS (
        SELECT DISTINCT ON (adsh) adsh, ni / eps * per_unit AS implied
        FROM (
            SELECT n.adsh, n.value_date, n.qtrs, COALESCE(MAX(u.shares_per_unit), 1) AS per_unit,
                   COALESCE(MAX(n.value) FILTER (WHERE n.tag = 'NetIncomeLoss'),
                            MAX(n.value) FILTER (WHERE n.tag = 'NetIncomeLossAvailableToCommonStockholdersBasic'),
                            MAX(n.value) FILTER (WHERE n.tag = 'ProfitLoss'),
                            MAX(n.value) FILTER (WHERE n.tag = 'IncomeLossFromContinuingOperations')) AS ni,
                   COALESCE(MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareBasic'),
                            MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareBasicAndDiluted'),
                            MAX(n.value) FILTER (WHERE n.tag = 'IncomeLossFromContinuingOperationsPerBasicShare'),
                            MAX(n.value) FILTER (WHERE n.tag = 'EarningsPerShareDiluted')) AS eps
            FROM sec_silver.num_silver n
            CROSS JOIN k
            LEFT JOIN unit u
              ON n.tradable_from >= u.filed_from AND (u.filed_to IS NULL OR n.tradable_from < u.filed_to)
            WHERE n.cik = p_cik
              AND n.coreg IS NULL AND n.value IS NOT NULL
              AND (n.segments IS NULL
                   OR (n.tag = 'EarningsPerShareBasic' AND n.segments = 'ClassOfStock=' || u.unit_member || ';'))
              AND n.tag IN ('NetIncomeLoss', 'NetIncomeLossAvailableToCommonStockholdersBasic', 'ProfitLoss',
                            'IncomeLossFromContinuingOperations',
                            'EarningsPerShareBasic', 'EarningsPerShareBasicAndDiluted',
                            'IncomeLossFromContinuingOperationsPerBasicShare', 'EarningsPerShareDiluted')
              AND n.tradable_from <= k.d
              AND (n.adsh IN (SELECT adsh FROM facts) OR n.adsh IN (SELECT adsh FROM cover))
            GROUP BY n.adsh, n.value_date, n.qtrs
        ) f
        WHERE ni IS NOT NULL AND eps IS NOT NULL AND ni <> 0 AND ABS(eps) >= 0.01
        ORDER BY adsh, qtrs DESC, value_date DESC
    ),
    -- A RESTATEMENT ITS OWN FILING REFUTES DOES NOT SUPERSEDE. A later
    -- filing's comparative replaces the earlier figure for the same
    -- period, and when the comparative is the one mis-scaled the right
    -- figure vanishes: Berkshire's 10-Q of 2012-05-07 restates the
    -- quarter of 2011-03-31 as 1,648,411,000,000 equivalent A shares, the
    -- 10-Q of 2011-05-09 had 1,648,411, and with every count of the
    -- year between mis-scaled the same way, May to July 2012 fell back to
    -- a count of 2010 (3% short). The original stays visible when the
    -- restatement is a thousand-fold off it, the restating filing's own
    -- net income over EPS refutes the restatement (333 times or more)
    -- and the original filing's confirms the original within a fifth.
    -- Both anchors are required: without them nothing says which of the
    -- two is wrong, and the restatement supersedes as before. Weighted
    -- averages only, because net income over EPS IS a weighted average,
    -- so it confirms one; it bounds only the scale of an instant count,
    -- and an instant count a comparative had hidden can be wrong in
    -- another way: Nabors' 10-K issued count of 2015-2016 includes the
    -- ~50M shares its subsidiaries hold (its cover counts exclude them
    -- from 2016: 283M against 333.5M), and reinstated it read 18% high
    -- for 21 months (found by the snapshot diff, 2026-11-10). CASE, not
    -- AND: no division may see a zero.
    visible AS (
        SELECT f.tag, f.value, f.value_date, f.tradable_from, f.segments, f.qtrs, f.adsh
        FROM facts f
        CROSS JOIN k
        LEFT JOIN anchor ao ON ao.adsh = f.adsh AND f.superseded_tradable <= k.d
        LEFT JOIN anchor ar ON ar.adsh = f.next_adsh AND f.superseded_tradable <= k.d
        WHERE f.superseded_tradable > k.d OR f.superseded_tradable IS NULL
           OR CASE WHEN f.tag LIKE 'WeightedAverage%'
                         AND f.value > 0 AND f.next_value > 0 AND ao.implied IS NOT NULL AND ar.implied IS NOT NULL
                   THEN (f.next_value / f.value >= 333 OR f.value / f.next_value >= 333)
                    AND ABS(f.value / ao.implied) BETWEEN 0.8 AND 1.25
                    AND ABS(f.next_value / ar.implied) NOT BETWEEN 1.0 / 333 AND 333
                   ELSE FALSE END
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
        -- COMPLETE SUMS ONLY. A sum that leaves out a mapped class the
        -- filer reports at the same date, under any instant share tag, is
        -- a part, not the whole: Molson Coors tags its Class B as issued
        -- but, on 78 dates, not as outstanding, and its outstanding sum
        -- was its 2.6M Class A alone, 1.3% of the company. Required are
        -- the mapped classes the filer reports, not every mapped label:
        -- Comcast named its Special class four ways over the years, one
        -- per filing.
        HAVING COUNT(DISTINCT sc.class_label) >= (
            SELECT COUNT(DISTINCT sc2.class_label)
            FROM visible v2
            JOIN sec_reference.share_class sc2
              ON sc2.cik = p_cik
             AND v2.segments = 'ClassOfStock=' || sc2.class_label || ';'
             AND NOT sc2.is_excluded
             AND v2.value_date >= sc2.effective_from
             AND (sc2.effective_to IS NULL OR v2.value_date < sc2.effective_to)
            WHERE v2.value_date = v.value_date
              AND (v2.tag = v.tag
                   OR (v.tag IN ('CommonStockSharesOutstanding', 'CommonStockSharesIssued')
                       AND v2.tag IN ('CommonStockSharesOutstanding', 'CommonStockSharesIssued')))
              AND (v2.qtrs = v.qtrs OR v2.tag IN ('CommonStockSharesOutstanding', 'CommonStockSharesIssued'))
        )
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
               c.rung, c.qtrs, c.implied, c.same_tag_far, c.shares AS gross_shares, c.adsh
        FROM (
            SELECT * FROM consolidated
            UNION ALL
            SELECT * FROM by_class
            UNION ALL
            -- The last resort: a cover-page count, rung 10, chosen only when
            -- no other candidate survives (Lockheed Martin and General
            -- Dynamics, whose share facts DERA drops; a count refused below).
            -- Not for an issuer in the share-class mapping, whose
            -- undimensioned cover may count one class (Berkshire's is its
            -- Class A, 941,481 shares); not when the cover is more than 400
            -- days old on the knowledge date; and only within a factor of
            -- two of the newest knowable count its net income over EPS
            -- implies, so a last resort is never the plausible-looking
            -- wrong answer (without that reference, nothing).
            SELECT cv.shares, cv.cover_date, cv.tradable_from,
                   'EntityCommonStockSharesOutstanding'::TEXT, 'cover_page'::TEXT, 10,
                   0, a.implied, FALSE, cv.adsh, FALSE
            FROM cover cv LEFT JOIN anchor a ON a.adsh = cv.adsh
            CROSS JOIN k CROSS JOIN implied_any ia
            WHERE cv.cover_date >= k.d - 400
              AND cv.shares / ia.implied BETWEEN 0.5 AND 2
              AND NOT EXISTS (SELECT 1 FROM sec_reference.share_class sc WHERE sc.cik = p_cik)
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
        SELECT l.*, MAX(l.value_date) FILTER (WHERE l.rung <> 10) OVER () AS newest_period,
                    MAX(l.value_date) FILTER (WHERE l.rung = 10) OVER () AS newest_cover
        FROM netted l
        WHERE l.shares > 0
          -- CONTRADICTED TWICE. A balance-sheet or class-summed count that
          -- its own filing's cover count AND its own net income over EPS
          -- both put more than a fifth away is refused: Aflac's 1,359M
          -- issued against a cover of 560M and an EPS count of 513M,
          -- Colgate, Nordson, Everest, Citrix (whose "outstanding" is its
          -- issued count). One reference is not enough, since a merger
          -- moves one of them legitimately: the cover is dated weeks after
          -- the period end, the EPS count is the period's average. In 92%
          -- of the counts refused the two references agree with each
          -- other within a fifth (measured 2026-11-09).
          -- The referee cover is the filing's own, else, when the frames
          -- kept another filing's count for that quarter, the first cover
          -- dated within 200 days after the count (Nordson's 10-K issued
          -- count, 98M against 58M outstanding, had no same-filing cover).
          AND NOT (l.rung <= 5 AND l.implied IS NOT NULL
                   AND ABS(l.shares / l.implied) NOT BETWEEN 0.8 AND 1.25
                   AND EXISTS (SELECT 1 FROM (
                                   SELECT cv.shares FROM cover cv
                                   WHERE cv.adsh = l.adsh
                                      OR cv.cover_date BETWEEN l.value_date AND l.value_date + 200
                                   ORDER BY (cv.adsh = l.adsh) DESC, cv.cover_date
                                   LIMIT 1) r
                               WHERE l.shares / r.shares NOT BETWEEN 0.8 AND 1.25))
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
    -- A count more than 400 days older than the newest knowable cover
    -- count is stale and ranks below it: once Colgate's issued counts are
    -- refused, its newest surviving balance-sheet count is from 2009.
    -- Otherwise a cover count is the last resort: an instant count within
    -- 400 days of the newest period first, as before, then the newest
    -- period, the most trustworthy rung and the shortest average.
    ORDER BY (rung <> 10 AND newest_cover IS NOT NULL AND value_date < newest_cover - 400) ASC,
             (rung <= 5 AND value_date >= newest_period - 400) DESC,
             (rung = 10) ASC,
             value_date DESC,
             rung ASC,
             qtrs ASC
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_gold.shares_outstanding_at(INTEGER, DATE, INTEGER) IS
    'Share count knowable on p_asof, by priority ladder with mapped '
    'share-class summation. method: consolidated | issued_less_treasury | '
    'class_sum_mapped | class_sum_less_treasury | class_sum_as_converted | '
    'cover_page; an '
    'issued count has the treasury shares of the same balance-sheet date '
    'subtracted; an issuer flagged as_converted_eps in share_class is the '
    'filing''s net income over its listed class''s basic EPS, the company '
    'in that class''s units (Visa); a balance-sheet count contradicted by '
    'both its filing''s cover count and its net income over EPS is refused, '
    'and a cover-page count (cover_share_count) is the last resort. '
    'A count more than 333 times, or less than a 333rd of, the filing''s '
    'own net income over basic EPS is refused as mis-scaled; without that '
    'anchor, a count contradicted that far by the same tag in another '
    'filing within 400 days is refused; a weighted average its own filing '
    'refutes that far does not supersede an original its filing confirms. '
    'Counts a filer states per unit of the whole company (share_unit: '
    'Berkshire''s equivalent Class A share) are converted into the priced '
    'class. An instant count within 400 days of the newest period beats a '
    'weighted average. NOT sufficient for market cap on multi-class '
    'issuers - that needs each class priced separately (177 of 1,569 '
    'tracked companies hold more than one listed ticker, 2026-09-04); '
    'use share_classes_at.';
