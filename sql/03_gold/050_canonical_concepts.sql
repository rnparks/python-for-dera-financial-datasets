-- Canonical concept mapping for hedge fund research.
--
-- Replaces the 4-row metric_aliases table (which is kept for backward
-- compatibility with sec_gold.get_pit_financials) with a real taxonomy
-- layer. A "concept" is a research-meaningful metric like revenue or
-- total_debt. Each concept maps to one or more XBRL tags in priority
-- order, with optional industry overrides (sic_prefix). The companion
-- function sec_gold.get_canonical() walks this map to resolve any
-- (cik, concept, period) tuple to a single canonical value.
--
-- Design notes:
--   - sic_prefix uses '' (empty string) for "any industry" rather than
--     NULL so the PRIMARY KEY (concept, tag, sic_prefix) stays simple
--     and industry-specific overrides rank ahead of generic rules at
--     query time (ORDER BY sic_prefix <> '' DESC, priority ASC).
--   - priority is per (concept, industry): 1 = try first.
--   - sign_multiplier is usually +1 but set to -1 for tags that are
--     reported as negative numbers (e.g., some CostOfRevenue variants).

-- All three tables, so this file can be re-run on its own after a
-- mapping change (peer_stats goes with them and 080 recreates it). It
-- once dropped only the first two, and a standalone re-run failed on
-- concept_formula already existing.
DROP TABLE IF EXISTS sec_gold.concept_ratio       CASCADE;
DROP TABLE IF EXISTS sec_gold.concept_formula     CASCADE;
DROP TABLE IF EXISTS sec_gold.concept_tag_map     CASCADE;
DROP TABLE IF EXISTS sec_gold.canonical_concepts  CASCADE;

CREATE TABLE sec_gold.canonical_concepts (
    concept       TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL,
    fact_type     TEXT NOT NULL CHECK (fact_type IN ('flow','balance','ratio','growth','derived')),
    expected_uom  TEXT NOT NULL,
    description   TEXT
);

INSERT INTO sec_gold.canonical_concepts VALUES
    ('revenue',              'Total Revenue',           'flow',    'USD',       'Top-line revenue for the period'),
    ('gross_profit',         'Gross Profit',            'flow',    'USD',       'Revenue minus cost of goods sold'),
    ('operating_income',     'Operating Income',        'flow',    'USD',       'Profit from core operations before tax/interest'),
    ('net_income',           'Net Income',              'flow',    'USD',       'Bottom-line profit attributable to shareholders'),
    ('eps_diluted',          'Diluted EPS',             'flow',    'USD/share', 'Diluted earnings per common share'),
    ('cash',                 'Cash and Equivalents',    'balance', 'USD',       'Cash, equivalents and (for non-banks) short-term investments'),
    ('total_assets',         'Total Assets',            'balance', 'USD',       'Balance sheet total assets'),
    ('total_equity',         'Total Equity',            'balance', 'USD',       'Stockholders equity (incl. noncontrolling interest when available)'),
    ('total_debt',           'Total Debt',              'balance', 'USD',       'Best-effort total interest-bearing debt from the dominant XBRL tag'),
    ('operating_cash_flow',  'Cash from Operations',    'flow',    'USD',       'Net cash provided by operating activities'),
    ('capex',                'Capital Expenditures',    'flow',    'USD',       'Payments to acquire property, plant and equipment'),
    ('free_cash_flow',       'Free Cash Flow',          'derived', 'USD',       'Operating cash flow minus capex'),
    -- Components. Useful alone, and they are the operands the formulas
    -- in concept_formula are assembled from.
    ('cost_of_revenue',      'Cost of Revenue',         'flow',    'USD',       'Cost of goods and services sold'),
    ('debt_noncurrent',      'Long-Term Debt',          'balance', 'USD',       'Debt due beyond one year, excluding the current portion'),
    ('debt_current',         'Current Debt',            'balance', 'USD',       'Current portion of long-term debt plus short-term borrowings'),
    -- Scale-free concepts, defined in concept_ratio below: a ratio of two
    -- concepts at one period, or one concept's change over its own prior
    -- fiscal year. Never priced: nothing here needs a market value.
    ('gross_margin',         'Gross Margin',            'ratio',   'ratio',     'Gross profit over revenue'),
    ('operating_margin',     'Operating Margin',        'ratio',   'ratio',     'Operating income over revenue'),
    ('net_margin',           'Net Margin',              'ratio',   'ratio',     'Net income over revenue'),
    ('fcf_margin',           'Free Cash Flow Margin',   'ratio',   'ratio',     'Free cash flow over revenue'),
    ('roe',                  'Return on Equity',        'ratio',   'ratio',     'Net income over fiscal year-end total equity; undefined when equity is not positive'),
    ('roa',                  'Return on Assets',        'ratio',   'ratio',     'Net income over fiscal year-end total assets'),
    ('debt_to_equity',       'Debt to Equity',          'ratio',   'ratio',     'Total debt over total equity; undefined when equity is not positive'),
    ('revenue_growth',       'Revenue Growth',          'growth',  'ratio',     'Revenue change over the prior fiscal year; undefined from a non-positive base'),
    ('net_income_growth',    'Net Income Growth',       'growth',  'ratio',     'Net income change over the prior fiscal year; undefined from a loss'),
    ('eps_growth',           'Diluted EPS Growth',      'growth',  'ratio',     'Diluted EPS change over the prior fiscal year; undefined from a loss'),
    ('operating_cash_flow_growth', 'Operating Cash Flow Growth', 'growth', 'ratio', 'Operating cash flow change over the prior fiscal year; undefined from a non-positive base');

CREATE TABLE sec_gold.concept_tag_map (
    concept          TEXT NOT NULL REFERENCES sec_gold.canonical_concepts (concept) ON DELETE CASCADE,
    tag              TEXT NOT NULL,
    priority         SMALLINT NOT NULL,
    sign_multiplier  SMALLINT NOT NULL DEFAULT 1 CHECK (sign_multiplier IN (-1, 1)),
    sic_prefix       TEXT NOT NULL DEFAULT '',
    notes            TEXT,
    PRIMARY KEY (concept, tag, sic_prefix)
);

CREATE INDEX idx_concept_tag_map_concept ON sec_gold.concept_tag_map (concept, priority);

-- Revenue ----------------------------------------------------------
--
-- The pre-2018 tags matter. ASC 606 retired SalesRevenueNet and its
-- siblings in the 2018 taxonomy, and before that they were the dominant
-- top-line tags for product companies. Without them peer_stats resolved
-- revenue for 628 of 1,361 tracked issuers in FY2015 against 1,479 in
-- FY2024 (measured 2026-09-04), so anything backtested before 2018 ran
-- on half a universe with nothing in the output to say so. Check 13 in
-- tools/verify_pit.sql now guards FY2015 as well as FY2024.
--
-- SalesRevenueGoodsNet and SalesRevenueServicesNet are COMPONENTS, and a
-- component is only a safe stand-in for the total when it is the only
-- one filed: an issuer filing both without any total would resolve to
-- the goods line alone and understate revenue. Measured before mapping
-- them: of the 233 tracked issuers still without FY2015 revenue after
-- SalesRevenueNet, 111 file goods only, 43 services only and NONE file
-- both. Check 37 asserts that shape stays absent, so the day an issuer
-- files both components and no total, the suite says so rather than
-- the table quietly halving its revenue.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('revenue', 'RevenueFromContractWithCustomerExcludingAssessedTax', 1, 'ASC 606 standard, used by most non-financial issuers'),
    ('revenue', 'Revenues',                                            2, 'Pre-ASC 606 fallback and used by some financials (BAC, C, PNC)'),
    ('revenue', 'RevenuesNetOfInterestExpense',                        3, 'Large-bank headline revenue tag (JPM, WFC, others)'),
    ('revenue', 'RevenueFromContractWithCustomerIncludingAssessedTax', 4, 'ASC 606 variant that includes sales taxes'),
    ('revenue', 'SalesRevenueNet',                                     5, 'Pre-ASC 606 (retired 2018) total sales; 470 tracked issuers used it for FY2015 and resolved to nothing'),
    ('revenue', 'RealEstateRevenueNet',                                6, 'REIT rental revenue total; 31 tracked issuers file only this'),
    ('revenue', 'SalesRevenueGoodsNet',                                7, 'Pre-ASC 606 goods component; safe only because no tracked issuer files it alongside SalesRevenueServicesNet without a total (check 37)'),
    ('revenue', 'SalesRevenueServicesNet',                             8, 'Pre-ASC 606 services component; same guard as above');
-- Banks (SIC 60) — prefer Revenues or RevenuesNetOfInterestExpense over the non-financial default
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'Revenues',                            1, '60', 'Some banks file plain Revenues'),
    ('revenue', 'RevenuesNetOfInterestExpense',        2, '60', 'Large-bank headline revenue (JPM, WFC)'),
    ('revenue', 'InterestAndDividendIncomeOperating',  3, '60', 'Fallback: gross interest income'),
    ('revenue', 'InterestIncomeOperating',             4, '60', 'Fallback: gross interest income, the variant without dividends');
-- Non-bank lenders (SIC 61: card issuers, consumer finance). Discover
-- (6141) and Synchrony (6199) file the bank tags and nothing the
-- non-financial default lists, so they resolved to no revenue at all.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'Revenues',                            1, '61', 'Same treatment as banks'),
    ('revenue', 'RevenuesNetOfInterestExpense',        2, '61', 'Same treatment as banks'),
    ('revenue', 'InterestAndDividendIncomeOperating',  3, '61', 'Fallback: gross interest income (Discover)'),
    ('revenue', 'InterestIncomeOperating',             4, '61', 'Fallback: gross interest income (Synchrony)');
-- REITs (SIC 6798). Rental income under ASC 842 is OperatingLeaseLeaseIncome
-- and 5 tracked REITs file only that. An industry row outranks every
-- generic row, so the totals a REIT may file are restated here above it:
-- 40 tracked REITs file both, and the total must keep winning.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'Revenues',                                            1, '6798', 'Total, when filed'),
    ('revenue', 'RevenueFromContractWithCustomerExcludingAssessedTax', 2, '6798', 'Total, when filed'),
    ('revenue', 'RealEstateRevenueNet',                                3, '6798', 'Rental revenue total'),
    ('revenue', 'OperatingLeaseLeaseIncome',                           4, '6798', 'ASC 842 rental income; the only revenue line 5 tracked REITs file');
-- Regulated utilities (SIC 49) — 11 S&P 1500 issuers including NextEra
-- report only this tag, so they resolved to no revenue at all before.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'RegulatedAndUnregulatedOperatingRevenue', 1, '49', 'Standard regulated-utility revenue line'),
    ('revenue', 'Revenues',                                2, '49', 'Utility fallback');

-- Gross profit -----------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('gross_profit', 'GrossProfit', 1, 'Direct XBRL tag — companies that file a gross profit line');

-- Cost of revenue --------------------------------------------------
-- Only exists so gross_profit can be derived where GrossProfit is not
-- filed. 641 issuers file CostOfGoodsAndServicesSold, 208 CostOfRevenue.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('cost_of_revenue', 'CostOfGoodsAndServicesSold', 1, 'ASC 606-era standard cost line'),
    ('cost_of_revenue', 'CostOfRevenue',              2, 'Older/alternate cost line');

-- Operating income -------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('operating_income', 'OperatingIncomeLoss', 1, 'Near-universal for non-financials');

-- Net income -------------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('net_income', 'NetIncomeLoss',                                     1, 'Net income including noncontrolling interest'),
    ('net_income', 'NetIncomeLossAvailableToCommonStockholdersBasic',   2, 'Fallback for companies that lead with "available to common"');

-- EPS diluted ------------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('eps_diluted', 'EarningsPerShareDiluted', 1, 'Near-universal (1449 S&P 1500 companies at FY2024)');

-- Cash -------------------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('cash', 'CashAndCashEquivalentsAtCarryingValue',                         1, 'Standard non-bank issuer cash line'),
    ('cash', 'CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents', 2, 'ASC 230 hierarchical total — larger population, includes restricted'),
    ('cash', 'Cash',                                                          3, 'Legacy tag, small population');
-- Banks (SIC 60) — they use CashAndDueFromBanks which includes Federal Reserve deposits
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('cash', 'CashAndDueFromBanks',                                                 1, '60', 'Primary bank cash line'),
    ('cash', 'CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents',       2, '60', 'Fallback when CashAndDueFromBanks is not filed');

-- Total assets -----------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('total_assets', 'Assets', 1, 'Near-universal (1488 S&P 1500 companies)');

-- Total equity -----------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('total_equity', 'StockholdersEquity',                                                     1, 'Most common equity tag (1419 companies)'),
    ('total_equity', 'StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest', 2, 'Alternate for consolidated groups with minority interest');

-- Total debt -------------------------------------------------------
-- No single XBRL tag captures "total interest-bearing debt" cleanly, so
-- this resolves in two stages: a combined tag when the issuer files one,
-- otherwise the formula in concept_formula sums the noncurrent and
-- current components.
--
-- `LongTermDebtNoncurrent` was previously priority 3 HERE, which was the
-- real defect. It resolved for most issuers and excludes the current
-- portion, so total_debt was not merely sparse at 53% coverage, it was
-- silently UNDERSTATED wherever it did resolve. A leverage ratio built
-- on it is wrong, which is worse than missing. It now lives on
-- debt_noncurrent, where it belongs, and total_debt falls through to the
-- sum.
--
-- Deliberately NOT mapped here: RepaymentsOfLongTermDebt (579 issuers)
-- and ProceedsFromIssuanceOfLongTermDebt (516). Both rank high in any
-- tag-frequency scan and both are cash-flow movements, not balances.
--
-- Every tag below is a us-gaap element (checked against num.version on
-- 2026-09-04: zero custom uses), filed undimensioned on the face. The
-- totals are totals by taxonomy definition. The components were added
-- from the FY2024 S&P 500 gap: 88 members had no total_debt, and the
-- ones that file debt at all use convertible, senior, unsecured or
-- notes-payable lines that no row here named. What is still NOT mapped,
-- on purpose: REIT secured/unsecured pairs and bank borrowings/deposits
-- (sibling components with no total; summing them needs double-count
-- guards this table cannot express), and anything dimensioned (GM,
-- PACCAR, Textron, Deere tag their debt by segment).
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('total_debt', 'DebtLongtermAndShorttermCombinedAmount',                           1, 'Cleanest roll-up but only filed by ~17 companies'),
    ('total_debt', 'LongTermDebt',                                                     2, 'Older single-tag usage; already a total'),
    ('total_debt', 'LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities', 3, 'Total including current maturities; JPMorgan (401B) and US Bancorp file only this'),
    ('total_debt', 'DebtAndCapitalLeaseObligations',                                   4, 'Total debt plus capital leases; Berkshire, Aflac, Host Hotels');

-- Debt components --------------------------------------------------
-- Ordered broad to narrow, so an issuer filing a notes-payable line and
-- a convertible sub-line resolves to the broader one.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('debt_noncurrent', 'LongTermDebtNoncurrent',                        1, 'Most commonly filed long-term debt line'),
    ('debt_noncurrent', 'LongTermDebtAndCapitalLeaseObligations',        2, 'Issuers that fold finance leases into debt'),
    ('debt_noncurrent', 'LongTermNotesPayable',                          3, 'Notes payable, noncurrent (Autodesk, Omnicom, Axon)'),
    ('debt_noncurrent', 'LongTermNotesAndLoans',                         4, 'Notes and loans, noncurrent (Oracle, Corpay)'),
    ('debt_noncurrent', 'UnsecuredLongTermDebt',                         5, 'Unsecured long-term debt (Goldman Sachs 243B, CME, Cadence)'),
    ('debt_noncurrent', 'SeniorLongTermNotes',                           6, 'Senior notes, noncurrent (VeriSign, Electronic Arts, Arch Capital)'),
    ('debt_noncurrent', 'ConvertibleLongTermNotesPayable',               7, 'Convertible notes, noncurrent (ServiceNow, Akamai, Super Micro)'),
    ('debt_noncurrent', 'ConvertibleDebtNoncurrent',                     8, 'Convertible debt, noncurrent'),
    ('debt_current',    'LongTermDebtCurrent',                           1, 'Current portion of long-term debt'),
    ('debt_current',    'LongTermDebtAndCapitalLeaseObligationsCurrent', 2, 'Current portion including finance leases'),
    ('debt_current',    'DebtCurrent',                                   3, 'Current debt in total: current maturities plus short-term borrowings'),
    ('debt_current',    'NotesPayableCurrent',                           4, 'Notes payable, current'),
    ('debt_current',    'NotesAndLoansPayableCurrent',                   5, 'Notes and loans, current'),
    ('debt_current',    'UnsecuredDebtCurrent',                          6, 'Unsecured debt, current'),
    ('debt_current',    'SeniorNotesCurrent',                            7, 'Senior notes, current'),
    ('debt_current',    'ConvertibleNotesPayableCurrent',                8, 'Convertible notes, current'),
    ('debt_current',    'ConvertibleDebtCurrent',                        9, 'Convertible debt, current'),
    ('debt_current',    'ShortTermBorrowings',                          10, 'Short-term borrowings alone; last because DebtCurrent already includes them when both are filed');

-- Operating cash flow ---------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('operating_cash_flow', 'NetCashProvidedByUsedInOperatingActivities', 1, 'Near-universal');

-- Capex ------------------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('capex', 'PaymentsToAcquirePropertyPlantAndEquipment', 1, 'Most common capex tag (~1008 S&P 1500 companies)'),
    ('capex', 'PaymentsToAcquireProductiveAssets',          2, 'Industrials and utilities fallback (~210 companies)');
-- Note: a few hundred S&P 1500 issuers (NVDA is a notable example) use
-- custom company-extension capex tags not covered here. features.md
-- tracks "long tail tag coverage" as a Tier-3 follow-up.

-- Derived concepts -------------------------------------------------
--
-- Until now `fact_type` allowed 'derived' and 'ratio' and nothing ever
-- computed either. free_cash_flow had been declared with no tags and
-- then explicitly excluded from every consumer, so the enum was pure
-- forward-declaration. This table makes it real.
--
-- A derived concept is a linear combination of OTHER concepts. Keeping
-- it declarative rather than burying arithmetic in the resolver means a
-- new derived metric is an INSERT, not a code change, and the same
-- mechanism serves the growth metrics and factor work later.
--
-- Deliberately one level deep: every operand must itself resolve from
-- tags, never from another formula. That rules out recursion, cycles and
-- the ordering questions they bring, at the cost of writing
-- `revenue - cost_of_revenue` rather than chaining. Worth it.
--
-- `required` controls what a missing operand means:
--   TRUE  — the result is NULL without it. Gross profit is meaningless
--           if you know revenue but not cost.
--   FALSE — treat as zero. A company that reports no capex still has a
--           free cash flow, and one with only long-term debt still has
--           a total debt.
-- At least one operand must resolve either way, so a company with no
-- debt at all yields NULL rather than a misleading zero.
--
-- total_debt requires the NONCURRENT component. With both optional, an
-- issuer whose long-term debt is tagged by segment (Deere) or under a
-- line this table does not name resolved to its current portion alone:
-- Deere 15.9B against roughly 65B, Kenvue 2.4B, Conagra 1.0B, Air
-- Products 0.8B, EQT 0.3B, CarMax 0.2B -- 26 of 1,063 FY2024 totals,
-- every one silently understated. NULL is the honest answer there. The
-- current portion stays optional: no current maturities is common.

CREATE TABLE sec_gold.concept_formula (
    concept      TEXT     NOT NULL REFERENCES sec_gold.canonical_concepts (concept) ON DELETE CASCADE,
    operand      TEXT     NOT NULL REFERENCES sec_gold.canonical_concepts (concept),
    coefficient  SMALLINT NOT NULL CHECK (coefficient IN (-1, 1)),
    required     BOOLEAN  NOT NULL DEFAULT TRUE,
    notes        TEXT,
    PRIMARY KEY (concept, operand),
    CHECK (concept <> operand)
);

INSERT INTO sec_gold.concept_formula (concept, operand, coefficient, required, notes) VALUES
    -- Recovers 253 issuers that file cost but no gross profit line,
    -- taking coverage from 604 to 857. The ceiling is structural: banks,
    -- REITs and insurers do not report a gross profit line at all, so
    -- 857 of 1,569 is as far as this can go.
    ('gross_profit',   'revenue',             1, TRUE,  'Revenue minus cost of revenue'),
    ('gross_profit',   'cost_of_revenue',    -1, TRUE,  NULL),
    -- Both operands already resolved; this proves the mechanism on a
    -- concept that has been declared and uncomputed for months.
    ('free_cash_flow', 'operating_cash_flow', 1, TRUE,  'Operating cash flow minus capex'),
    ('free_cash_flow', 'capex',              -1, FALSE, 'A company with no capex still has FCF'),
    -- Fires only when no combined debt tag resolves. Fixes the
    -- understatement described above, and recovers 266 issuers.
    ('total_debt',     'debt_noncurrent',     1, TRUE,  'Sum of the two components when no combined tag exists; the noncurrent part is required, see above'),
    ('total_debt',     'debt_current',        1, FALSE, NULL);

COMMENT ON TABLE sec_gold.concept_formula IS
    'Derived concepts as linear combinations of other concepts. One '
    'level deep by design: operands must resolve from tags, never from '
    'another formula. Consulted only when direct tags fail.';

-- ---------------------------------------------------------------
-- Ratios and growth: scale-free concepts over the ones above.
-- ---------------------------------------------------------------
-- A ratio divides two concepts resolved at the SAME period; growth
-- compares one concept with its own value one fiscal year earlier.
-- Operands may be filed or formula-derived concepts (free_cash_flow,
-- total_debt) but never another ratio, so the graph stays two levels
-- deep at most and nothing can recurse. Where the denominator or the
-- base is not positive the answer is NULL, deliberately: a return on
-- negative equity, or growth from a loss, is not a number anyone should
-- rank on. Consumers: peer_stats (cross-sections, with the same peer
-- moments and percentiles as dollar concepts), latest_annual and
-- as_of_latest_annual (per company, so the snapshots carry them).
CREATE TABLE sec_gold.concept_ratio (
    concept      TEXT PRIMARY KEY REFERENCES sec_gold.canonical_concepts (concept) ON DELETE CASCADE,
    kind         TEXT NOT NULL CHECK (kind IN ('ratio', 'growth')),
    numerator    TEXT NOT NULL REFERENCES sec_gold.canonical_concepts (concept),
    denominator  TEXT REFERENCES sec_gold.canonical_concepts (concept),
    notes        TEXT,
    CHECK ((kind = 'ratio' AND denominator IS NOT NULL) OR (kind = 'growth' AND denominator IS NULL)),
    CHECK (concept <> numerator AND (denominator IS NULL OR concept <> denominator))
);

INSERT INTO sec_gold.concept_ratio (concept, kind, numerator, denominator, notes) VALUES
    ('gross_margin',               'ratio',  'gross_profit',        'revenue',      'gross_profit may itself be revenue - cost_of_revenue'),
    ('operating_margin',           'ratio',  'operating_income',    'revenue',      NULL),
    ('net_margin',                 'ratio',  'net_income',          'revenue',      NULL),
    ('fcf_margin',                 'ratio',  'free_cash_flow',      'revenue',      'free_cash_flow is always a formula'),
    ('roe',                        'ratio',  'net_income',          'total_equity', 'Fiscal year-end equity, not an average'),
    ('roa',                        'ratio',  'net_income',          'total_assets', 'Fiscal year-end assets, not an average'),
    ('debt_to_equity',             'ratio',  'total_debt',          'total_equity', 'total_debt requires the noncurrent component, so this is never current debt alone'),
    ('revenue_growth',             'growth', 'revenue',             NULL,           NULL),
    ('net_income_growth',          'growth', 'net_income',          NULL,           NULL),
    ('eps_growth',                 'growth', 'eps_diluted',         NULL,           NULL),
    ('operating_cash_flow_growth', 'growth', 'operating_cash_flow', NULL,           NULL);

COMMENT ON TABLE sec_gold.concept_ratio IS
    'Scale-free concepts: kind = ratio divides numerator by denominator '
    'at one period; kind = growth compares numerator with its own value '
    'one fiscal year earlier. NULL where the denominator or base is not '
    'positive. Operands are never ratios themselves.';
