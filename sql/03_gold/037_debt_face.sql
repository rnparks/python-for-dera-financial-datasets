-- The balance-sheet face, read for borrowings: one row per filing.
--
-- WHY. A company that has no debt files no debt tag, so the tag walk
-- (050) and its formulas resolve total_debt to NULL for it, and every
-- leverage cross-section silently drops the least-levered names. A
-- zero cannot come from the absence of a tag -- that is the plausible-
-- wrong answer this project refuses -- but it can come from the
-- statement itself: the filer printed a balance sheet, and no line on
-- it is a borrowing. This matview reads that face (sec_silver.pre_silver)
-- and records, per filing, what it found, so a zero is a cited fact
-- about one filing rather than an inference about a company.
--
-- THE RULE, per filing. A line in the liabilities section (after the
-- total-assets line, before the first equity line) is a BORROWING when
-- its printed label says so -- debt, borrowings, notes payable, line of
-- credit, term loan, senior/convertible notes, subordinated, mortgages
-- payable, repurchase agreements, FHLB advances, commercial paper,
-- financing obligations -- and does not say receivable, deposits,
-- deferred, lease (unless the line also says debt), and the like. The
-- face is DEBT-FREE when it is complete, no borrowing line carries a
-- positive value, no borrowing line lacks an undimensioned value, the
-- filing's interest expense (annualised) is at most 0.2% of total
-- assets, and the filer is not a bank or broker (SIC 60-62), whose
-- borrowings this rule does not judge. Everything else is NOT a zero:
-- it is left to the tag walk, and a borrowing line is never summed
-- here.
--
-- MEASURED 2026-09-11 before this existed, against the 135 S&P 400/600
-- members of 2024-12-31 with no plain debt tag, each verified two ways
-- (every DERA fact under any namespace or dimension; the FY2024 balance
-- sheet on an external site with leases separated): the rule produced
-- 90 zeros among the 109 verified debt-free and none among the 23 with
-- debt; the 19 verified debt-free it refuses show a debt line at "--"
-- or interest that contradicts an empty face. Over every FY2024 10-K
-- it gives 3,092 non-financials a borrowing line, 1,161 a zero, and
-- refuses 350 (203 with a line but no undimensioned value, 147 whose
-- interest -- finance leases, mostly -- contradicts an empty face).
-- Against the 1,202 members whose total_debt resolves from tags, no
-- resolved value was touched: this rule fills NULLs only.
--
-- Refreshed with the other gold matviews (cli.GOLD_MATVIEWS); its inputs
-- are silver and sec_reference.company (SIC).

DROP MATERIALIZED VIEW IF EXISTS sec_gold.debt_face CASCADE;

CREATE MATERIALIZED VIEW sec_gold.debt_face AS
WITH filings AS (
    SELECT s.adsh, s.cik, s.form, s.period_date, s.filed_date, s.tradable_from,
           COALESCE(s.sic, c.sic_latest) AS sic
    FROM sec_silver.sub_silver s
    LEFT JOIN sec_reference.company c ON c.cik = s.cik
    WHERE s.form IN ('10-K', '10-K/A', '10-KT', '10-Q', '10-Q/A', '10-QT')
      AND s.cik IS NOT NULL AND s.period_date IS NOT NULL
),
face AS (
    SELECT p.adsh, p.line, p.tag, p.version, p.plabel
    FROM sec_silver.pre_silver p
    JOIN filings f ON f.adsh = p.adsh
    WHERE p.stmt = 'BS' AND NOT p.inpth
),
bounds AS (
    SELECT adsh,
           MAX(line) FILTER (WHERE tag = 'Assets') AS assets_line,
           MIN(line) FILTER (WHERE tag IN ('LiabilitiesAndStockholdersEquity', 'LiabilitiesAndPartnersCapital')) AS end_line,
           MIN(line) FILTER (WHERE tag IN ('StockholdersEquity',
                                           'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest',
                                           'PartnersCapital', 'MembersEquity', 'CommonStockValue', 'PreferredStockValue')) AS equity_line
    FROM face GROUP BY adsh
),
-- The liabilities section, each line judged by its printed label.
liab AS (
    SELECT fa.adsh, fa.line, fa.tag, fa.version, fa.plabel,
           (lower(fa.plabel) ~ '(debt|borrow|notes? payable|note payable|loans? payable|loan payable|line of credit|lines of credit|credit facilit|credit agreement|term loan|revolv|debenture|bonds?( |,|$)|senior notes|convertible notes|convertible senior|subordinated|mortgages? payable|mortgage notes|mortgage loans? payable|repurchase agreement|sold under agreement|federal home loan bank|fhlb|financing obligation|financing|commercial paper|construction loan|securitiz|warehouse|notes?, net|notes?,? due|junior subordinated|trust preferred|promissory|securities due within|^(short-term|long-term|current maturities of long-term) obligations)'
            AND lower(fa.plabel) !~ '(receivable|held for|held-for|investment|available for sale|available-for-sale|deferred|accrued interest|interest payable|deposits|customer|contract|unearned|reserve|allowance|equity|stock|shares|capital|performance bond|guaranty|guarantee|warrant|derivative|pension|insurance|tax)'
            AND NOT (lower(fa.plabel) ~ 'lease' AND lower(fa.plabel) !~ '(debt|borrow|note|loan|financing obligation)')) AS is_borrowing
    FROM face fa
    JOIN bounds b USING (adsh)
    WHERE b.assets_line IS NOT NULL
      AND fa.line > b.assets_line
      AND fa.line < COALESCE(b.equity_line, b.end_line, 2147483647)
),
lines AS (
    SELECT l.adsh,
           COUNT(*) FILTER (WHERE l.is_borrowing)                       AS borrowing_lines,
           COUNT(*) FILTER (WHERE l.is_borrowing AND n.value > 0)       AS borrowing_lines_positive,
           COUNT(*) FILTER (WHERE l.is_borrowing AND n.value IS NULL)   AS borrowing_lines_unvalued,
           SUM(n.value) FILTER (WHERE l.is_borrowing)                   AS borrowing_sum,
           string_agg(l.plabel || ' [' || l.tag || CASE WHEN l.version NOT LIKE 'us-gaap%' THEN ', custom' ELSE '' END
                      || '=' || COALESCE(n.value::TEXT, 'no undimensioned value') || ']', ' | ' ORDER BY l.line)
               FILTER (WHERE l.is_borrowing)                             AS borrowing_labels,
           COUNT(*)                                                     AS liability_lines
    FROM liab l
    JOIN filings f ON f.adsh = l.adsh
    -- num_silver is indexed by (cik, tag, value_date, qtrs): the join
    -- names the company and date first, then the filing, so the index
    -- applies. Joined on adsh alone this scanned 185M rows per filing.
    LEFT JOIN sec_silver.num_silver n
           ON n.cik = f.cik AND n.tag = l.tag AND n.value_date = f.period_date AND n.qtrs = 0
          AND n.adsh = l.adsh AND n.version = l.version
          AND n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD'
    GROUP BY l.adsh
),
-- Interest expense in the same filing, annualised from the year-to-date
-- figure, and total assets: the corroboration a zero needs.
money AS (
    SELECT f.adsh,
           (SELECT n.value * 4.0 / n.qtrs
              FROM sec_silver.num_silver n
             WHERE n.cik = f.cik AND n.value_date = f.period_date AND n.qtrs BETWEEN 1 AND 4
               AND n.tag IN ('InterestExpense', 'InterestExpenseNonoperating', 'InterestExpenseDebt',
                             'InterestExpenseBorrowings', 'InterestExpenseLongTermDebt')
               AND n.adsh = f.adsh
               AND n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD'
             ORDER BY n.qtrs DESC, n.value DESC LIMIT 1) AS interest_annualised,
           (SELECT MAX(n.value) FROM sec_silver.num_silver n
             WHERE n.cik = f.cik AND n.tag = 'Assets' AND n.value_date = f.period_date AND n.qtrs = 0
               AND n.adsh = f.adsh
               AND n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD') AS assets
    FROM filings f
)
SELECT f.adsh, f.cik, f.form, f.period_date, f.filed_date, f.tradable_from, f.sic,
       b.assets_line IS NOT NULL AND COALESCE(b.equity_line, b.end_line) IS NOT NULL AS face_complete,
       COALESCE(li.liability_lines, 0)           AS liability_lines,
       COALESCE(li.borrowing_lines, 0)           AS borrowing_lines,
       COALESCE(li.borrowing_lines_positive, 0)  AS borrowing_lines_positive,
       COALESCE(li.borrowing_lines_unvalued, 0)  AS borrowing_lines_unvalued,
       li.borrowing_sum,
       li.borrowing_labels,
       m.interest_annualised,
       m.assets,
       CASE
           WHEN b.adsh IS NULL OR b.assets_line IS NULL OR COALESCE(b.equity_line, b.end_line) IS NULL THEN 'face incomplete'
           WHEN f.sic BETWEEN 6000 AND 6299 THEN 'bank or broker: not judged'
           WHEN COALESCE(li.borrowing_lines_positive, 0) > 0 THEN 'borrowing line present'
           WHEN COALESCE(li.borrowing_lines_unvalued, 0) > 0 THEN 'borrowing line without an undimensioned value'
           WHEN m.assets IS NULL OR m.assets <= 0 THEN 'no total assets'
           WHEN COALESCE(m.interest_annualised, 0) > 0.002 * m.assets THEN 'interest expense without a borrowing line'
           ELSE 'no borrowing line, interest nil'
       END AS reason,
       (b.adsh IS NOT NULL AND b.assets_line IS NOT NULL AND COALESCE(b.equity_line, b.end_line) IS NOT NULL
        AND NOT (f.sic BETWEEN 6000 AND 6299)
        AND COALESCE(li.borrowing_lines_positive, 0) = 0
        AND COALESCE(li.borrowing_lines_unvalued, 0) = 0
        AND m.assets > 0
        AND COALESCE(m.interest_annualised, 0) <= 0.002 * m.assets) AS zero_by_face
FROM filings f
LEFT JOIN bounds b ON b.adsh = f.adsh
LEFT JOIN lines  li ON li.adsh = f.adsh
LEFT JOIN money  m  ON m.adsh = f.adsh;

CREATE UNIQUE INDEX idx_debt_face_adsh ON sec_gold.debt_face (adsh);
CREATE INDEX idx_debt_face_cik_date  ON sec_gold.debt_face (cik, period_date);

COMMENT ON MATERIALIZED VIEW sec_gold.debt_face IS
    'The balance-sheet face of every 10-K and 10-Q, read for borrowing '
    'lines by the labels the filer printed. zero_by_face is TRUE when the '
    'face is complete, no borrowing line carries a value, interest is nil '
    'and the filer is not a bank; reason says why otherwise. The only '
    'source of a total_debt of zero, and it never overrides a filed figure.';
