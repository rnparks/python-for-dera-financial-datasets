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

-- All five tables, so this file can be re-run on its own after a
-- mapping change (peer_stats goes with them and 080 recreates it; 060,
-- 065, 070 and 085 must follow so the resolvers see the new shape). It
-- once dropped only the first two, and a standalone re-run failed on
-- concept_formula already existing.
DROP TABLE IF EXISTS sec_gold.concept_ratio       CASCADE;
DROP TABLE IF EXISTS sec_gold.concept_formula     CASCADE;
DROP TABLE IF EXISTS sec_gold.concept_formula_variant CASCADE;
DROP TABLE IF EXISTS sec_gold.concept_tag_map     CASCADE;
DROP TABLE IF EXISTS sec_gold.canonical_concepts  CASCADE;

CREATE TABLE sec_gold.canonical_concepts (
    concept       TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL,
    fact_type     TEXT NOT NULL CHECK (fact_type IN ('flow','balance','ratio','growth','derived')),
    expected_uom  TEXT NOT NULL,
    description   TEXT,
    -- Scored concepts are what peer_stats ranks and the snapshots list.
    -- An operand that means nothing on its own -- a bank's FHLB advances
    -- line -- resolves like any concept but is not scored.
    scored        BOOLEAN NOT NULL DEFAULT TRUE
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

-- INSTRUMENT LINES. A bank, a REIT or an insurer files no current /
-- noncurrent split: its balance sheet lists each borrowing as its own
-- line -- mortgages payable, unsecured notes, the revolver, FHLB
-- advances, subordinated debt, trust-preferred debentures -- and total
-- debt is their sum. Each line is a concept here so that the second
-- total_debt variant can add them (concept_formula below); within one
-- concept the tags are alternatives for the same line, across concepts
-- the lines are disjoint. Measured 2026-09-11 over every FY2024 10-K:
-- the common pairs (secured + unsecured 43 filers, line of credit +
-- secured 43, FHLB advances + subordinated 32) never carry the same
-- value, so they are lines, not restatements of one another. Not
-- scored: nobody ranks on a subordinated-debt line.
INSERT INTO sec_gold.canonical_concepts (concept, display_name, fact_type, expected_uom, description, scored) VALUES
    ('debt_secured',               'Secured Debt',                 'balance', 'USD', 'Collateralised debt (mortgages payable), current and noncurrent', FALSE),
    ('debt_secured_current',       'Secured Debt, Current',        'balance', 'USD', 'Current portion of collateralised debt, where the filer splits it', FALSE),
    ('debt_unsecured',             'Unsecured Debt',               'balance', 'USD', 'Uncollateralised debt (term loans, notes), current and noncurrent', FALSE),
    ('debt_senior_notes',          'Senior Notes',                 'balance', 'USD', 'Senior notes, current and noncurrent', FALSE),
    ('debt_line_of_credit',        'Line of Credit',               'balance', 'USD', 'Drawn revolving credit, current and noncurrent', FALSE),
    ('debt_line_of_credit_current','Line of Credit, Current',      'balance', 'USD', 'Current portion of drawn revolving credit, where the filer splits it', FALSE),
    ('debt_notes_payable',         'Notes Payable',                'balance', 'USD', 'Notes payable, current and noncurrent', FALSE),
    ('debt_loans_payable',         'Loans Payable',                'balance', 'USD', 'Loans payable (term loans, bank loans), current and noncurrent', FALSE),
    ('debt_loans_payable_current', 'Loans Payable, Current',       'balance', 'USD', 'Current portion of loans payable, where the filer splits it', FALSE),
    ('debt_convertible',           'Convertible Debt',             'balance', 'USD', 'Convertible notes, current and noncurrent', FALSE),
    ('debt_other_long_term',       'Other Long-Term Debt',         'balance', 'USD', 'Long-term debt classified as other', FALSE),
    ('debt_subordinated',          'Subordinated Debt',            'balance', 'USD', 'Subordinated debt', FALSE),
    ('debt_junior_subordinated',   'Junior Subordinated Debt',     'balance', 'USD', 'Junior subordinated debentures and notes (trust-preferred)', FALSE),
    ('debt_fhlb_advances',         'FHLB Advances',                'balance', 'USD', 'Federal Home Loan Bank advances, all maturities', FALSE),
    ('debt_fhlb_advances_current', 'FHLB Advances, Short-Term',    'balance', 'USD', 'Short-term FHLB advances, where the filer splits them', FALSE),
    ('debt_other_borrowings',      'Other Borrowings',             'balance', 'USD', 'Borrowings classified as other', FALSE),
    ('debt_short_term_borrowings', 'Short-Term Borrowings',        'balance', 'USD', 'Fed funds purchased, repos and other short-term borrowings', FALSE),
    ('debt_warehouse',             'Warehouse Borrowings',         'balance', 'USD', 'Warehouse lines of a mortgage lender', FALSE),
    ('debt_surplus_notes',         'Surplus Notes',                'balance', 'USD', 'Surplus notes of an insurer', FALSE);

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
    ('revenue', 'SalesRevenueServicesNet',                             8, 'Pre-ASC 606 services component; same guard as above'),
    ('revenue', 'RevenuesExcludingInterestAndDividends',               9, 'A total-revenue element a handful of non-financials file alone (Universal Corp 2.9B); 4 FY2024 filers');
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
    ('revenue', 'OperatingLeaseLeaseIncome',                           4, '6798', 'ASC 842 rental income; the only revenue line 5 tracked REITs file'),
    ('revenue', 'RevenueFromContractWithCustomerIncludingAssessedTax', 5, '6798', 'Total, when filed; restated above the interest line'),
    ('revenue', 'InterestAndDividendIncomeOperating',                  6, '6798', 'A mortgage REIT has no rental line: gross interest income is its top line (Ready Capital, Two Harbors, Redwood, Adamas)');
-- Brokers and advisers (SIC 62). Advisory boutiques file only
-- InvestmentBankingRevenue (Moelis 1.2B); Navient (6211) only gross
-- interest income. The totals are restated above both so a broker that
-- files Revenues beside a component keeps the total (Stifel, Goldman).
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'Revenues',                                            1, '62', 'Total, when filed'),
    ('revenue', 'RevenuesNetOfInterestExpense',                        2, '62', 'Net revenue of a large broker-dealer (Goldman, Morgan Stanley)'),
    ('revenue', 'RevenueFromContractWithCustomerExcludingAssessedTax', 3, '62', 'Total, when filed'),
    ('revenue', 'RevenueFromContractWithCustomerIncludingAssessedTax', 4, '62', 'Total, when filed'),
    ('revenue', 'InvestmentBankingRevenue',                            5, '62', 'The only revenue line an advisory boutique files (Moelis)'),
    ('revenue', 'InterestAndDividendIncomeOperating',                  6, '62', 'Gross interest income of a lender classified here (Navient 3.8B)');
-- Regulated utilities (SIC 49) — 11 S&P 1500 issuers including NextEra
-- report only this tag, so they resolved to no revenue at all before.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'RegulatedAndUnregulatedOperatingRevenue', 1, '49', 'Standard regulated-utility revenue line'),
    ('revenue', 'Revenues',                                2, '49', 'Utility fallback'),
    -- An industry row outranks every generic row, so the ASC 606 totals
    -- are restated here above the regulated line: of the 10 FY2024
    -- filers of RegulatedOperatingRevenue, 8 file a total beside it
    -- (Southern Company 12.5B against 8.0B regulated) and must keep it.
    ('revenue', 'RevenueFromContractWithCustomerExcludingAssessedTax', 3, '49', 'Total, when filed'),
    ('revenue', 'RevenueFromContractWithCustomerIncludingAssessedTax', 4, '49', 'Total, when filed'),
    ('revenue', 'RegulatedOperatingRevenue',               5, '49', 'The only revenue line a gas utility may file (ONE Gas 2.1B, Spire 3.2B)');

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
-- notes-payable lines that no row here named. The REIT secured /
-- unsecured pairs and the bank borrowing lines -- sibling components
-- with no total, which this table could not sum -- are the instrument
-- concepts above and the second total_debt variant below (2026-09-11).
-- Still NOT mapped, on purpose: anything dimensioned (GM, PACCAR,
-- Textron, Deere tag their debt by segment), and any instrument line
-- of a non-financial, whose lines are too often partial (see the
-- variant's notes).
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

-- Instrument lines (operands of the second total_debt variant). Within
-- a concept, priority orders alternatives for the same line: the tag
-- that includes both portions first, then the noncurrent form, then a
-- current-only form for the filers who report nothing else of that
-- instrument (a revolver classified current). The current-portion
-- concepts exist for the split pairs the taxonomy defines
-- (SecuredLongTermDebt + SecuredDebtCurrent: 23 FY2024 filers,
-- LongTermLineOfCredit + LinesOfCreditCurrent: 14) and would double
-- count only against the both-portions tag of the same instrument,
-- which those filers do not file. Every tag is a us-gaap element; the
-- definitions quoted are the taxonomy's.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('debt_secured',                'SecuredDebt',                                                     1, 'Collateralised debt, current and noncurrent portions (28 of the 49 FY2024 S&P 400/600 REITs without a total)'),
    ('debt_secured',                'SecuredLongTermDebt',                                             2, 'Collateralised debt due beyond one year'),
    ('debt_secured_current',        'SecuredDebtCurrent',                                              1, 'Current portion of collateralised long-term debt'),
    ('debt_unsecured',              'UnsecuredDebt',                                                   1, 'Uncollateralised debt, current and noncurrent portions (22 REITs)'),
    ('debt_senior_notes',           'SeniorNotes',                                                     1, 'Senior notes, current and noncurrent portions'),
    ('debt_line_of_credit',         'LineOfCredit',                                                    1, 'Drawn line of credit, current and noncurrent portions (24 REITs)'),
    ('debt_line_of_credit',         'LongTermLineOfCredit',                                            2, 'Drawn line of credit, noncurrent portion'),
    ('debt_line_of_credit',         'LinesOfCreditCurrent',                                            3, 'Drawn line of credit, current portion, for a filer that reports nothing else of it'),
    ('debt_line_of_credit_current', 'LinesOfCreditCurrent',                                            1, 'Current portion, alongside LongTermLineOfCredit'),
    ('debt_notes_payable',          'NotesPayable',                                                    1, 'Notes payable, current and noncurrent portions (CNO 1.8B)'),
    ('debt_notes_payable',          'NotesAndLoansPayable',                                            2, 'Notes and loans payable, both portions (CubeSmart)'),
    ('debt_notes_payable',          'OtherNotesPayable',                                               3, 'Notes payable classified as other'),
    ('debt_loans_payable',          'LoansPayable',                                                    1, 'Loans payable, current and noncurrent portions'),
    ('debt_loans_payable',          'LongTermLoansPayable',                                            2, 'Loans payable due beyond one year'),
    ('debt_loans_payable',          'LoansPayableToBank',                                              3, 'Bank loans, both portions'),
    ('debt_loans_payable',          'LongTermLoansFromBank',                                           4, 'Bank loans due beyond one year'),
    ('debt_loans_payable_current',  'LoansPayableToBankCurrent',                                       1, 'Current portion of bank loans'),
    ('debt_loans_payable_current',  'ShortTermBankLoansAndNotesPayable',                               2, 'Short-term bank loans and notes'),
    ('debt_convertible',            'ConvertibleNotesPayable',                                         1, 'Convertible notes, both portions'),
    ('debt_convertible',            'ConvertibleDebt',                                                 2, 'Convertible debt, both portions'),
    ('debt_other_long_term',        'OtherLongTermDebt',                                               1, 'Long-term debt classified as other (First Horizon 1.2B)'),
    ('debt_other_long_term',        'OtherLongTermDebtNoncurrent',                                     2, 'Other long-term debt, noncurrent portion'),
    ('debt_subordinated',           'SubordinatedDebt',                                                1, 'Subordinated debt, both portions (20 of the 50 FY2024 S&P 400/600 banks without a total)'),
    ('debt_subordinated',           'SubordinatedLongTermDebt',                                        2, 'Subordinated debt due beyond one year'),
    ('debt_junior_subordinated',    'JuniorSubordinatedDebentureOwedToUnconsolidatedSubsidiaryTrust',  1, 'Trust-preferred debentures (14 banks)'),
    ('debt_junior_subordinated',    'JuniorSubordinatedNotes',                                         2, 'Junior subordinated notes, both portions'),
    ('debt_junior_subordinated',    'JuniorSubordinatedLongTermNotes',                                 3, 'Junior subordinated notes due beyond one year'),
    ('debt_fhlb_advances',          'AdvancesFromFederalHomeLoanBanks',                                1, 'FHLB advances, all maturities (Pinnacle 1.9B)'),
    ('debt_fhlb_advances',          'FederalHomeLoanBankAdvancesLongTerm',                             2, 'FHLB advances initially due beyond one year, both portions (Wintrust 3.2B)'),
    ('debt_fhlb_advances',          'FederalHomeLoanBankAdvancesBranchOfFHLBBankAmountOfAdvancesByBranch', 3, 'FHLB advances, the by-branch element filed on the face'),
    ('debt_fhlb_advances',          'LongTermFederalHomeLoanBankAdvancesNoncurrent',                   4, 'FHLB advances, noncurrent portion'),
    ('debt_fhlb_advances_current',  'FederalHomeLoanBankAdvancesShortTerm',                            1, 'Short-term FHLB advances, alongside a long-term line'),
    ('debt_other_borrowings',       'OtherBorrowings',                                                 1, 'Other borrowings (19 banks)'),
    ('debt_other_borrowings',       'OtherShortTermBorrowings',                                        2, 'Other short-term borrowings'),
    ('debt_short_term_borrowings',  'ShortTermBorrowings',                                             1, 'Fed funds purchased, repos and other short-term borrowings; a line of its own for a bank (First Financial Bankshares files nothing else)'),
    ('debt_warehouse',              'WarehouseAgreementBorrowings',                                    1, 'Warehouse lines of a mortgage lender'),
    ('debt_surplus_notes',          'SurplusNotes',                                                    1, 'Surplus notes of an insurer');

-- Operating cash flow ---------------------------------------------
-- TAG-NAME FAMILIES, and how this table treats each. The taxonomy
-- spells one idea several ways, and the rule differs by family:
--   * Current / Noncurrent / IncludingCurrentMaturities: components and
--     totals of a balance -- mapped to the component concepts or the
--     total, never both (see total_debt).
--   * IncludingAssessedTax / ExcludingAssessedTax: the same revenue with
--     or without pass-through taxes -- both mapped, excluding first.
--   * ContinuingOperations: a subtotal that excludes discontinued
--     operations. For a cash-flow subtotal it is what a filer reports
--     INSTEAD of the plain tag when its statement has that line, and
--     for a filer with no discontinued operations it is the same
--     number: 5,331 companies use it for operating cash flow, 3,944 of
--     them with no plain tag at the same period (27,213 filings, Apple's
--     FY2014 and FY2015 10-Ks among them; measured 2026-09-05), which
--     left free_cash_flow, fcf_margin and OCF growth missing or stale
--     for all of them. Mapped at priority 2, so the plain tag wins
--     where both exist. Income-statement ContinuingOperations tags
--     (IncomeLossFromContinuingOperations) are a DIFFERENT concept from
--     net income and are not mapped to it.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('operating_cash_flow', 'NetCashProvidedByUsedInOperatingActivities',                     1, 'Near-universal'),
    ('operating_cash_flow', 'NetCashProvidedByUsedInOperatingActivitiesContinuingOperations', 2, 'The continuing-operations subtotal, filed instead of the plain tag by 3,944 companies (Apple FY2014-15)');

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

-- A formula comes in VARIANTS, tried in order; the first whose
-- operands satisfy it wins, and a filed figure beats any of them at the
-- same period. A variant can be confined to industries (sic_prefixes)
-- and can carry a GUARD: a regex over the filer's plain balance-sheet
-- tags at that date in a custom namespace, and when one matches, the
-- variant yields nothing. The guard exists for the instrument sum:
-- measured 2026-09-11, 51 of the 212 banks and 39 of the 129 REITs
-- whose lines would be summed also carry a company-extension debt line
-- -- Home Bancshares' "AdvancesFromFederalHomeLoanBanksAndOtherBorrowings"
-- (601M beside 439M of subordinated debt in us-gaap), Omega
-- Healthcare's "SeniorNotesAndOtherUnsecuredBorrowingsNet" (its notes,
-- beside 243M of secured debt) -- and a sum of the us-gaap lines alone
-- would be the plausible, wrong answer. Those resolve to nothing; the
-- rest to their balance sheet's own arithmetic.
CREATE TABLE sec_gold.concept_formula_variant (
    concept       TEXT     NOT NULL REFERENCES sec_gold.canonical_concepts (concept) ON DELETE CASCADE,
    variant       SMALLINT NOT NULL,
    sic_prefixes  TEXT[]   NOT NULL DEFAULT '{}',   -- empty: any industry
    guard_match   TEXT,                             -- regex; NULL: no guard
    guard_except  TEXT,                             -- regex; a match here is not a match above
    notes         TEXT,
    PRIMARY KEY (concept, variant)
);

CREATE TABLE sec_gold.concept_formula (
    concept      TEXT     NOT NULL REFERENCES sec_gold.canonical_concepts (concept) ON DELETE CASCADE,
    variant      SMALLINT NOT NULL DEFAULT 1,
    operand      TEXT     NOT NULL REFERENCES sec_gold.canonical_concepts (concept),
    coefficient  SMALLINT NOT NULL CHECK (coefficient IN (-1, 1)),
    required     BOOLEAN  NOT NULL DEFAULT TRUE,
    notes        TEXT,
    PRIMARY KEY (concept, variant, operand),
    FOREIGN KEY (concept, variant) REFERENCES sec_gold.concept_formula_variant (concept, variant) ON DELETE CASCADE,
    CHECK (concept <> operand)
);

INSERT INTO sec_gold.concept_formula_variant (concept, variant, sic_prefixes, guard_match, guard_except, notes) VALUES
    ('gross_profit',   1, '{}', NULL, NULL, 'Revenue minus cost of revenue'),
    ('free_cash_flow', 1, '{}', NULL, NULL, 'Operating cash flow minus capex'),
    ('total_debt',     1, '{}', NULL, NULL, 'The split: noncurrent (required) plus current'),
    ('total_debt',     2, '{60,63,6798}',
        '(Debt|Borrowing|NotesPayable|LoansPayable|Advances|Debenture|LineOfCredit|CreditFacilit|TermLoan|Bonds?|SeniorNotes|Subordinated)',
        '(Receivable|Servicing|Stock|Deposit|Asset|Escrow|Enhancement|InterestExpense|InterestIncome|InterestRate|InterestPayable|AccruedInterest|InterestBearing|Expense|FairValue|Cost|Deferred|Allowance|Income|Loss|Gain|HeldFor|HeldTo|Sale|InvestmentsHeld|InvestmentSecurit|InvestmentIn|Securit|Percent|Rate|Capacity|Availab|Maturit|Issu|Repay|Proceed|^(DebtInstrument|LongTermDebt|Debt|Notes|SeniorNotes|ConvertibleDebt)Unamortized|DiscountOn|PremiumOn|Accrued|Payment|Commitment|Guarantee|Covenant|Equity|Tax|Weighted|Number|Count|Restricted)',
        'The instrument lines of a bank (SIC 60), an insurer (63) or a REIT (6798), summed. The guard exempts the premium and discount elements themselves (DebtInstrumentUnamortizedPremium) but not a line named after one: Brixmor files its 5.3B of mortgages as MortgagesPayableIncludingUnamortizedPremium, and a blanket Unamortized|Discount|Premium exclusion let that kind of line past the guard (found 2026-09-11 verifying the no-debt-line members; no member of the 2024-12-31 panel changes). Not for a non-financial: measured 2026-09-11, 98 of the 259 non-financial sums with an interest-expense line implied a rate over 15%, the lines being partial (a revolver in us-gaap, the term loan in a custom tag). Guarded against a custom debt line at the same date.');

INSERT INTO sec_gold.concept_formula (concept, variant, operand, coefficient, required, notes) VALUES
    -- Recovers 253 issuers that file cost but no gross profit line,
    -- taking coverage from 604 to 857. The ceiling is structural: banks,
    -- REITs and insurers do not report a gross profit line at all, so
    -- 857 of 1,569 is as far as this can go.
    ('gross_profit',   1, 'revenue',             1, TRUE,  'Revenue minus cost of revenue'),
    ('gross_profit',   1, 'cost_of_revenue',    -1, TRUE,  NULL),
    -- Both operands already resolved; this proves the mechanism on a
    -- concept that has been declared and uncomputed for months.
    ('free_cash_flow', 1, 'operating_cash_flow', 1, TRUE,  'Operating cash flow minus capex'),
    ('free_cash_flow', 1, 'capex',              -1, FALSE, 'A company with no capex still has FCF'),
    -- Fires only when no combined debt tag resolves. Fixes the
    -- understatement described above, and recovers 266 issuers.
    ('total_debt',     1, 'debt_noncurrent',     1, TRUE,  'Sum of the two components when no combined tag exists; the noncurrent part is required, see above'),
    ('total_debt',     1, 'debt_current',        1, FALSE, NULL),
    -- The instrument sum. Every line optional, at least one present
    -- (the resolver's rule); no current-portion concept of the split
    -- form here, because the both-portions lines already include it.
    ('total_debt',     2, 'debt_secured',                1, FALSE, 'Mortgages payable'),
    ('total_debt',     2, 'debt_secured_current',        1, FALSE, 'Only beside SecuredLongTermDebt'),
    ('total_debt',     2, 'debt_unsecured',              1, FALSE, NULL),
    ('total_debt',     2, 'debt_senior_notes',           1, FALSE, NULL),
    ('total_debt',     2, 'debt_line_of_credit',         1, FALSE, NULL),
    ('total_debt',     2, 'debt_line_of_credit_current', 1, FALSE, 'Only beside LongTermLineOfCredit'),
    ('total_debt',     2, 'debt_notes_payable',          1, FALSE, NULL),
    ('total_debt',     2, 'debt_loans_payable',          1, FALSE, NULL),
    ('total_debt',     2, 'debt_loans_payable_current',  1, FALSE, NULL),
    ('total_debt',     2, 'debt_convertible',            1, FALSE, NULL),
    ('total_debt',     2, 'debt_other_long_term',        1, FALSE, NULL),
    ('total_debt',     2, 'debt_subordinated',           1, FALSE, NULL),
    ('total_debt',     2, 'debt_junior_subordinated',    1, FALSE, NULL),
    ('total_debt',     2, 'debt_fhlb_advances',          1, FALSE, NULL),
    ('total_debt',     2, 'debt_fhlb_advances_current',  1, FALSE, 'Only beside FederalHomeLoanBankAdvancesLongTerm'),
    ('total_debt',     2, 'debt_other_borrowings',       1, FALSE, NULL),
    ('total_debt',     2, 'debt_short_term_borrowings',  1, FALSE, 'A line of its own for a bank; for a non-financial it stays in debt_current, never a total alone'),
    ('total_debt',     2, 'debt_warehouse',              1, FALSE, NULL),
    ('total_debt',     2, 'debt_surplus_notes',          1, FALSE, NULL);

COMMENT ON TABLE sec_gold.concept_formula_variant IS
    'The variants of a derived concept, tried in order: an industry scope '
    'and a guard against a custom-namespace balance tag at the same date. '
    'The first variant whose operands satisfy it wins; a filed figure '
    'beats every variant at the same period.';
COMMENT ON TABLE sec_gold.concept_formula IS
    'Derived concepts as linear combinations of other concepts, per '
    'variant. One level deep by design: operands must resolve from tags, '
    'never from another formula. Consulted only when direct tags fail.';

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
