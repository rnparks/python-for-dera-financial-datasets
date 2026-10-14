-- Industry-specific quality descriptors for financials, as of a date.
--
-- The nine factors of the factor sheet are built for industrials: a bank
-- has no gross profit and no operating margin, and three of its remaining
-- measures divide by a balance sheet that is leverage by design, so under
-- a sector-relative quality sort banks filled Financials' bottom fifth
-- (26% of bank company-months in the S&P 1500, 2% in the top, measured
-- 2026-10-14). Scoring within the industry group and restricting a bank to
-- the comparable measures (tools/score_methods.py) level the groups but
-- still score a bank on what the sheet has. These are the measures a
-- bank's, an insurer's and a REIT's own analysts use, computed point in
-- time from the same silver facts the rest of gold reads, with the same
-- rules: only facts knowable on the date (tradable_from, superseded), only
-- undimensioned consolidated values, nothing from sec_gold.suspect_fact.
--
--   rote            net income / (equity - goodwill - other intangibles)
--                   tangible equity is equity less the filed
--                   IntangibleAssetsNetIncludingGoodwill or
--                   GoodwillAndIntangibleAssetsNet, else less Goodwill and,
--                   when filed, IntangibleAssetsNetExcludingGoodwill; NULL
--                   when no us-gaap goodwill line is filed (JPMorgan files
--                   its goodwill, servicing assets and intangibles as one
--                   custom line; 6% of the panel's banks)
--   ppnr_at         (net interest income + non-interest income
--                    - non-interest expense) / assets   pre-provision profit
--   efficiency      non-interest expense / (net interest income
--                    + non-interest income)             lower is better
--   nii_at          net interest income / assets         the margin, on
--                   total rather than earning assets
--   provisions_at   provision for credit losses / assets  lower is better;
--                   the first filed of six provision tags (the pre-CECL
--                   provision lines and the CECL credit-loss expense); assets
--                   rather than loans because the loan line is filed on
--                   64% of bank years and assets on 100%
--   loss_ratio      policyholder benefits and claims / premiums earned
--                   lower is better
--   insurer_margin  (revenues - benefits, losses and expenses) / revenues
--                   the insurer's pre-tax margin, the operating margin an
--                   insurer never files
--   ffo_be, ffo_at  funds from operations (net income + depreciation and
--                   amortisation - gains on property sales) over equity and
--                   over assets: an approximation of NAREIT FFO, which also
--                   adds back impairments and adjusts for joint ventures.
--                   The gains line is the first filed of five us-gaap
--                   tags; an unfiled one is read as none (Prologis files its
--                   gains under custom tags and reads 1.2 points high)
--
-- All from the newest fiscal year (qtrs = 4 flows, qtrs = 0 balances at
-- the same period end) whose net income is knowable on the date. A
-- descriptor is NULL when any of its inputs is not filed for that year;
-- nothing is imputed from a neighbour. Coverage, measured 2026-10-14 over
-- the factor panel's companies: banks (SIC 60) file the three income lines
-- on 99% of company-years and all three at one period end with assets on
-- 96% of 10-K years; insurers (63) file premiums and claims on 78%; REITs
-- (6798) a depreciation line on 87%. The function stores nothing; the
-- research tool caches its output outside the database.
--
-- Not sufficient on its own for a quality sort: tools/score_methods.py
-- combines these with the comparable measures under
-- --financial-measures specific, by SIC group (banks and credit 6000-6199,
-- insurance 6300-6499, REITs 6798).

DROP FUNCTION IF EXISTS sec_gold.financial_descriptors_asof(INTEGER, DATE, INTEGER);

CREATE OR REPLACE FUNCTION sec_gold.financial_descriptors_asof(
    p_cik              INTEGER,
    p_asof             DATE,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    annual_period   DATE,
    tradable_from   DATE,
    rote            NUMERIC,
    ppnr_at         NUMERIC,
    efficiency      NUMERIC,
    nii_at          NUMERIC,
    provisions_at   NUMERIC,
    loss_ratio      NUMERIC,
    insurer_margin  NUMERIC,
    ffo_be          NUMERIC,
    ffo_at          NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH k AS (SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d),
    visible AS (
        SELECT n.tag, n.qtrs, n.value, n.value_date, n.tradable_from
        FROM sec_silver.num_silver n, k
        WHERE n.cik = p_cik
          AND n.coreg IS NULL AND n.segments IS NULL
          AND n.value IS NOT NULL AND n.uom = 'USD'
          AND (   (n.qtrs = 4 AND n.tag IN ('NetIncomeLoss', 'InterestIncomeExpenseNet', 'NoninterestIncome', 'NoninterestExpense',
                                            'ProvisionForLoanLeaseAndOtherLosses', 'ProvisionForCreditLosses',
                                            'ProvisionForLoanLossesExpensed', 'ProvisionForLoanAndLeaseLosses',
                                            'FinancingReceivableCreditLossExpenseReversal',
                                            'FinancingReceivableExcludingAccruedInterestCreditLossExpenseReversal',
                                            'PremiumsEarnedNet', 'PolicyholderBenefitsAndClaimsIncurredNet', 'BenefitsLossesAndExpenses',
                                            'Revenues', 'DepreciationDepletionAndAmortization', 'DepreciationAndAmortization',
                                            'GainLossOnSaleOfProperties', 'GainsLossesOnSalesOfInvestmentRealEstate',
                                            'GainLossOnSaleOfPropertiesNetOfApplicableIncomeTaxes',
                                            'GainLossOnDispositionOfAssets1', 'GainLossOnDispositionOfAssets'))
               OR (n.qtrs = 0 AND n.tag IN ('StockholdersEquity', 'Assets', 'Goodwill', 'IntangibleAssetsNetExcludingGoodwill',
                                            'IntangibleAssetsNetIncludingGoodwill', 'GoodwillAndIntangibleAssetsNet')))
          AND n.tradable_from <= k.d
          AND (n.superseded_tradable > k.d OR n.superseded_tradable IS NULL)
          AND NOT EXISTS (SELECT 1 FROM sec_gold.suspect_fact x
                           WHERE x.cik = p_cik AND x.tag = n.tag AND x.value_date = n.value_date AND x.qtrs = n.qtrs)
    ),
    period AS (
        SELECT value_date FROM visible WHERE tag = 'NetIncomeLoss' AND qtrs = 4
        ORDER BY value_date DESC LIMIT 1
    ),
    f AS (
        SELECT p.value_date AS annual_period, MAX(v.tradable_from) AS tradable_from,
               MAX(v.value) FILTER (WHERE v.tag = 'NetIncomeLoss')                          AS ni,
               MAX(v.value) FILTER (WHERE v.tag = 'StockholdersEquity')                     AS eq,
               MAX(v.value) FILTER (WHERE v.tag = 'Assets')                                 AS at,
               MAX(v.value) FILTER (WHERE v.tag = 'Goodwill')                               AS gw,
               MAX(v.value) FILTER (WHERE v.tag = 'IntangibleAssetsNetExcludingGoodwill')   AS intang,
               COALESCE(MAX(v.value) FILTER (WHERE v.tag = 'IntangibleAssetsNetIncludingGoodwill'),
                        MAX(v.value) FILTER (WHERE v.tag = 'GoodwillAndIntangibleAssetsNet'))   AS intang_incl,
               MAX(v.value) FILTER (WHERE v.tag = 'InterestIncomeExpenseNet')               AS nii,
               MAX(v.value) FILTER (WHERE v.tag = 'NoninterestIncome')                      AS nonii,
               MAX(v.value) FILTER (WHERE v.tag = 'NoninterestExpense')                     AS nonie,
               COALESCE(MAX(v.value) FILTER (WHERE v.tag = 'ProvisionForLoanLeaseAndOtherLosses'),
                        MAX(v.value) FILTER (WHERE v.tag = 'ProvisionForCreditLosses'),
                        MAX(v.value) FILTER (WHERE v.tag = 'ProvisionForLoanLossesExpensed'),
                        MAX(v.value) FILTER (WHERE v.tag = 'ProvisionForLoanAndLeaseLosses'),
                        MAX(v.value) FILTER (WHERE v.tag = 'FinancingReceivableCreditLossExpenseReversal'),
                        MAX(v.value) FILTER (WHERE v.tag = 'FinancingReceivableExcludingAccruedInterestCreditLossExpenseReversal'))  AS prov,
               MAX(v.value) FILTER (WHERE v.tag = 'PremiumsEarnedNet')                      AS prem,
               MAX(v.value) FILTER (WHERE v.tag = 'PolicyholderBenefitsAndClaimsIncurredNet') AS claims,
               MAX(v.value) FILTER (WHERE v.tag = 'BenefitsLossesAndExpenses')              AS ble,
               MAX(v.value) FILTER (WHERE v.tag = 'Revenues')                               AS rev,
               COALESCE(MAX(v.value) FILTER (WHERE v.tag = 'DepreciationDepletionAndAmortization'),
                        MAX(v.value) FILTER (WHERE v.tag = 'DepreciationAndAmortization'))     AS da,
               COALESCE(MAX(v.value) FILTER (WHERE v.tag = 'GainLossOnSaleOfProperties'),
                        MAX(v.value) FILTER (WHERE v.tag = 'GainsLossesOnSalesOfInvestmentRealEstate'),
                        MAX(v.value) FILTER (WHERE v.tag = 'GainLossOnSaleOfPropertiesNetOfApplicableIncomeTaxes'),
                        MAX(v.value) FILTER (WHERE v.tag = 'GainLossOnDispositionOfAssets1'),
                        MAX(v.value) FILTER (WHERE v.tag = 'GainLossOnDispositionOfAssets'), 0) AS gains
        FROM visible v JOIN period p ON v.value_date = p.value_date
        GROUP BY p.value_date
    )
    SELECT annual_period, tradable_from,
           CASE WHEN intang_incl IS NOT NULL THEN ni / NULLIF(eq - intang_incl, 0)
                WHEN gw IS NOT NULL          THEN ni / NULLIF(eq - gw - COALESCE(intang, 0), 0) END AS rote,
           (nii + nonii - nonie) / NULLIF(at, 0)                                                  AS ppnr_at,
           nonie / NULLIF(nii + nonii, 0)                                                         AS efficiency,
           nii / NULLIF(at, 0)                                                                    AS nii_at,
           prov / NULLIF(at, 0)                                                                   AS provisions_at,
           claims / NULLIF(prem, 0)                                                               AS loss_ratio,
           (rev - ble) / NULLIF(rev, 0)                                                           AS insurer_margin,
           (ni + da - gains) / NULLIF(eq, 0)                                                      AS ffo_be,
           (ni + da - gains) / NULLIF(at, 0)                                                      AS ffo_at
    FROM f;
$$;

COMMENT ON FUNCTION sec_gold.financial_descriptors_asof(INTEGER, DATE, INTEGER) IS
    'Bank, insurer and REIT quality descriptors knowable on p_asof from the '
    'newest fiscal year: return on tangible equity, pre-provision profit to '
    'assets, efficiency ratio, net interest income to assets, provisions to '
    'assets, loss ratio, insurer pre-tax margin, FFO to equity and to assets. '
    'NULL where an input is not filed for that year. Stores nothing; '
    'tools/score_methods.py --financial-measures specific uses it.';
