# Compustat-style items

`dera_pipeline/compustat.py` evaluates `data/reference/compustat_item_map.csv`:
for each Compustat item a published predictor uses (AT, CEQ, DLC, XSGA, ...), a
ladder of US-GAAP tags and formula variants over other items, each row citing the
definitions it rests on. Quarterly items are declared in
`data/reference/compustat_quarterly_items.csv` by reference to their annual item.

## Why a map, not a tag per item

S&P's definition of an item is rarely one XBRL element. Measured against S&P's
own documentation (as of 2026-10-01):

| Item | S&P definition | Rule |
|---|---|---|
| `dlc` | current portion of long-term debt plus short-term notes (DD1 + NP) | `DebtCurrent`, else current LTD + `ShortTermBorrowings` (which already includes commercial paper) |
| `xsga` | SG&A including research and development expense | `SellingGeneralAndAdministrativeExpense` + `ResearchAndDevelopmentExpense` |
| `cogs` | excludes depreciation allocated to cost of sales and amortization of intangibles | the excluding-D&A elements, else as-filed cost of revenue less D&A tagged inside it |
| `ceq` | SEQ − PSTK | `StockholdersEquity` − `PreferredStockValue` |
| `dltt` | long-term debt including capitalized leases | `LongTermDebtAndCapitalLeaseObligations` before `LongTermDebtNoncurrent` |
| `dvc` | common dividends declared, from the equity statement | `DividendsCommonStock` before cash paid |

## Export

`uv run python tools/export_compustat.py` writes `data/exports/compustat/annual.parquet`
(not tracked; read-only against the database): one row per (cik, fiscal year end,
availability date), with every exported item. A fiscal year gets a new row each
time a filing changes what was knowable about it, so an as-of join on `avail`
returns the vintage an investor had. Units are Compustat's: dollars and shares in
millions, per-share items in dollars. As of 2026-10-01: 116,099 firm-years for
13,808 companies, 298,185 rows.

## Quarterly export

`uv run python tools/export_compustat_quarterly.py` writes
`data/exports/compustat/quarterly.parquet`: one row per company and fiscal
quarter, with `fqtr`, `fyearq`, `rdq` (the first NYSE session the quarter's facts
were tradable) and the items of `data/reference/compustat_quarterly_items.csv`.
Fourth-quarter flows, which a 10-K does not tag, are the year less the nine
months to the third quarter end; year-to-date items take the fact whose duration
is the fiscal quarter. Values are as first reported (later vintages of a quarter
are not yet followed). Checked against check 64: Apple's FY2024 quarters read
90,753 / 85,777 / 94,930 revenue and 62,585 / 91,443 year-to-date operating cash
flow ($M), as the database's own trailing functions do. As of 2026-10-01:
446,053 company-quarters, 13,791 companies.

## Audit

`uv run python tools/audit_compustat_items.py` (after the export) checks the items
against S&P's own balancing model and writes `docs/audits/compustat_items.md`.
S&P's "other" items are remainders by definition (Current Assets – Other is what
is not cash, receivables or inventory), so `aco`, `lco`, `lo` and `ao` are the
remainder of their totals, falling back to the single XBRL "other" line only when
the total is not filed; the test for them is that they are not negative. As of
2026-10-01, operating companies (SIC not 6xxx, assets over $10M, positive sales),
43,781 firm-years: AT = LT + SEQ + MIB + temporary equity within 1% of assets in
95.0% (96.4% with every component filed; 67% before the remainder and liability
fallbacks); the four remainders are non-negative in 99.9–100.0%.

## Rules

A tag ladder resolves first; then formula variants in order, each needing its
required terms, counting optional terms as zero, and needing at least one term
present. Formulas may use other items; `validate()` refuses a cycle, an unknown
item, a tag outside the 2011–2026 US-GAAP taxonomy, and a tag whose FASB period
type differs from the item's. `tests/test_pure_functions.py` pins the rules and
runs `validate()` on the shipped map.

## Evidence

- **S&P's definitions**: the Compustat North America User's Guide (8/2003),
  chapter 5, and S&P's Xpressfeed balancing model (item hierarchy and
  identities such as ACT = CHE + RECT + INVT + ACO). Extracted, with every name
  match verified, in the companion research repository
  (`oap-research/docs/osap_rebuild/compustat_definitions.md`,
  `compustat_model.csv`). <!-- check-docs:ignore other repository -->
- **FASB's definitions**: `data/reference/usgaap_element_docs.csv`
  (`tools/fetch_usgaap_element_docs.py`), which describes every tag the map uses.

## Footnote items

Three Compustat files come from footnotes, which `sec_data` does not hold (it
loads the primary statements only). `tools/export_notes_items.py` builds them from
the SEC Financial Statement and Notes data sets (`docs/data_sources.md`, source
7) with the pure functions in `dera_pipeline/notes_items.py`. Only annual reports
count, only facts dated at the report's own fiscal period end, and the first
accepted report per company and period end wins (first reported). Amounts in
millions.

**Pensions** (`pensions.parquet`; Compustat `aco_pnfnda`). S&P (User's Guide
8/2003, ch. 5): since SFAS 132 Compustat no longer splits over- and underfunded
plans, so `pplao` (Pension Plan Assets) is the fair value of all defined-benefit
pension plan assets and `pbpro` (Pension – Projected Benefit Obligation) the PBO of
all defined-benefit pension plans, foreign plans included (footnote IK); OPEB plans
are excluded. Elements: `DefinedBenefitPlanFairValueOfPlanAssets`,
`DefinedBenefitPlanBenefitObligation`. The filing's pension total is taken from an
allowlist of members of the plan-type axis (`RetirementPlanTypeAxis`, before it
`DefinedBenefitPlansDisclosuresDefinedBenefitPlansAxis`), in order:

| Rule | Facts used |
|---|---|
| `pension_total` | the plan-type axis alone, on `PensionPlansDefinedBenefit` / `PensionPlan` / `DefinedBenefitPensionPlan` |
| `dom_plus_for` | domestic + foreign pension members (`UnitedStatesPensionPlansOfUSEntityDefinedBenefit` + `ForeignPensionPlansDefinedBenefit`, or the pension member with `RetirementPlanSponsorLocationAxis` domestic and foreign) |
| `one_location` | only one of those two present |
| `undimensioned` | the undimensioned fact, only when the filing tags no plan-type member on that element |

Plan assets and the PBO take the first rule both support (`common_rule`), so they
describe the same plans; a report where they share none gets neither.

The undimensioned fact is refused whenever plan-type members are present: in filings
that carry the undimensioned figure, a pension member and a non-zero OPEB member,
the undimensioned PBO equalled the pension plan in 9 of 20 and pension plus OPEB in
3 (2009–2012 archives), so it is not reliably either. `paddml`, `pcupsu`, `pbnaa`,
`pbnvv`, `pbpru` and `pplau` are null by S&P's own definitions: `pcupsu` is Not
Available for SFAS 87 adopters, the additional minimum liability ended with SFAS
158 (2006), and the over/underfunded splits with SFAS 132. Audit: the plan's own
`DefinedBenefitPlanFundedStatusOfPlan`, chosen by the same rule, must equal plan
assets minus PBO; `tools/export_notes_items.py` prints the share that does. As of
2026-10-01, on the archives through 2016q2: 3,458 of 3,735 reports within 1% of the
PBO, and 142 more where the filer reported the funded status with its sign
reversed (an underfunded plan as a positive number), a sign error in that
element rather than in assets or PBO.

**Segments** (`segments.parquet`; Compustat segment file, `stype` BUSSEG). One row
per annual report and member of `StatementBusinessSegmentsAxis`, from a revenue
fact on that axis alone (or with `ConsolidationItems=OperatingSegments`). `sales` is
the first present of: revenue from external customers, then total revenue elements
(`SALES_PRIORITY`). `snms` is the member name split into words. Compustat assigns
each segment a SIC (`sics1`) and NAICS (`naicsh`); XBRL members carry only a name,
so the only codes assigned are the sin-industry codes OSAP's `sinAlgo` tests,
from the name (`SIN_SEGMENTS`: tobacco 2111, beer 2082, wine 2084, spirits 2085,
gambling NAICS 713210; bare "gaming" excluded because it names video-game
segments). Every other segment's codes are null, so predictors that need a SIC
for every segment (OSAP's `retConglomerate`) cannot use this file.

**Customers** (`customers.parquet`; Compustat customer segment file). One row per
annual report and member of `MajorCustomersAxis`; `cnms` is the member name split
into words, `ctype` is GOVERNMENT for government payers, UNKNOWN for anonymous
members ("Customer A", "Top Ten Customers": most of them), else COMPANY; `salecs`
the largest revenue fact on that member, when one is tagged.

**AOCI components** (`aoci.parquet`; Compustat `recta`, `msa`). S&P: RECTA is the
cumulative translation adjustment reported as a separate component of equity, MSA
the marketable-securities adjustment so reported, excluding SFAS 133 hedging
adjustments. Both live in the equity footnote, so the statement map
(`compustat_item_map.csv`) resolves them for only 1–2% of firm-years. From the
Notes facts: the component's own element undimensioned
(`AccumulatedOtherComprehensiveIncomeLossForeignCurrencyTranslationAdjustmentNetOfTax`,
`AccumulatedOtherComprehensiveIncomeLossAvailableForSaleSecuritiesAdjustmentNetOfTax`),
else `AccumulatedOtherComprehensiveIncomeLossNetOfTax` on the equity-components axis
alone with an allowlisted member (`AOCI_MEMBER`); hedging reserves are never MSA.

## Not mapped

`spi` (special items: no single element), `emp` (employees: a cover-page
disclosure outside the financial statements), `fatb`/`fatl`/`ppenb`/`ppenls` (PP&E
by class), `ob` (order backlog), `fopt` and `wcapch` (pre-1988 statement of
changes items), `cshrc`, `ibcom`. Descriptors (`fyear`, `sich`, `datadate`) and
prices (`prcc_c`, `prcc_f`) come from the filing index and the price panel, not
from the map.
