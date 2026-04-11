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

DROP TABLE IF EXISTS sec_gold.concept_tag_map     CASCADE;
DROP TABLE IF EXISTS sec_gold.canonical_concepts  CASCADE;

CREATE TABLE sec_gold.canonical_concepts (
    concept       TEXT PRIMARY KEY,
    display_name  TEXT NOT NULL,
    fact_type     TEXT NOT NULL CHECK (fact_type IN ('flow','balance','ratio','derived')),
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
    ('free_cash_flow',       'Free Cash Flow',          'derived', 'USD',       'Operating cash flow minus capex (computed client-side)');

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
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('revenue', 'RevenueFromContractWithCustomerExcludingAssessedTax', 1, 'ASC 606 standard, used by most non-financial issuers'),
    ('revenue', 'Revenues',                                            2, 'Pre-ASC 606 fallback and used by some financials (BAC, C, PNC)'),
    ('revenue', 'RevenuesNetOfInterestExpense',                        3, 'Large-bank headline revenue tag (JPM, WFC, others)'),
    ('revenue', 'RevenueFromContractWithCustomerIncludingAssessedTax', 4, 'ASC 606 variant that includes sales taxes');
-- Banks (SIC 60) — prefer Revenues or RevenuesNetOfInterestExpense over the non-financial default
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, sic_prefix, notes) VALUES
    ('revenue', 'Revenues',                            1, '60', 'Some banks file plain Revenues'),
    ('revenue', 'RevenuesNetOfInterestExpense',        2, '60', 'Large-bank headline revenue (JPM, WFC)'),
    ('revenue', 'InterestAndDividendIncomeOperating',  3, '60', 'Fallback: gross interest income');

-- Gross profit -----------------------------------------------------
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('gross_profit', 'GrossProfit', 1, 'Direct XBRL tag — companies that file a gross profit line');

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
-- No single XBRL tag captures "total interest-bearing debt" cleanly.
-- This is a best-effort rollup: prefer a combined total tag, fall back
-- to the most common long-term-debt tags. features.md tracks a Tier-2
-- item to compute proper total_debt as sum of current + long-term +
-- short-term borrowings.
INSERT INTO sec_gold.concept_tag_map (concept, tag, priority, notes) VALUES
    ('total_debt', 'DebtLongtermAndShorttermCombinedAmount', 1, 'Cleanest roll-up but only filed by ~17 companies'),
    ('total_debt', 'LongTermDebt',                           2, 'Older single-tag usage'),
    ('total_debt', 'LongTermDebtNoncurrent',                 3, 'Most commonly filed but excludes current portion and short-term borrowings');

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

-- free_cash_flow is 'derived' fact_type and has no tags — clients compute
-- it from operating_cash_flow minus capex. Documented via description.
