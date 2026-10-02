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
months to the third quarter end (share counts, which are averages, take the year's
weighted average instead); year-to-date items take the fact whose duration is the
fiscal quarter. Point in time: `rdq` is the first 10-Q or 10-K tradable on or
after the quarter end that carries the quarter's balance sheet or own-period
flows, and every value is the one known by then. A value first reported in a
later filing (next year's comparative) is excluded, as is a fact dated tradable
before its quarter ended; before this rule, 25.7% of company-quarters carried a
number first reported more than 45 days after the date the row was used. Later
vintages of a quarter are not followed. Checked against check 64: Apple's FY2024 quarters read
90,753 / 85,777 / 94,930 revenue and 62,585 / 91,443 year-to-date operating cash
flow ($M), as the database's own trailing functions do. As of 2026-10-01:
447,451 company-quarters, 13,813 companies.

## Audit

`uv run python tools/audit_compustat_items.py` (after the export) checks the items
against S&P's own balancing model and writes `docs/audits/compustat_items.md`.
S&P's "other" items are remainders by definition (Current Assets – Other is what
is not cash, receivables or inventory), so `aco`, `lco`, `lo` and `ao` are the
remainder of their totals, falling back to the single XBRL "other" line only when
the total is not filed; the test for them is that they are not negative. As of
2026-10-01, operating companies (SIC not 6xxx, assets over $10M, positive sales),
first vintage, 44,119 firm-years: AT = LT + SEQ + MIB within 1% of assets in 97.0%
of the 41,383 with every component filed (95.0% before the review fixes of
2026-10-01); the four remainders are non-negative in 99.9–100.0%. The variant that
adds temporary equity reads 93.1%: since `seq` now includes redeemable preferred
presented in temporary equity (Presentation rules), that identity counts it twice
for those filers.

## Rules

A tag ladder resolves first; then formula variants in order, each needing its
required terms, counting optional terms as zero, and needing at least one term
present. Formulas may use other items; `validate()` refuses a cycle, an unknown
item, a tag outside the 2011–2026 US-GAAP taxonomy, and a tag whose FASB period
type differs from the item's. `tests/test_pure_functions.py` pins the rules and
runs `validate()` on the shipped map.

Fact vintages. At each availability date the vintage in force is the latest
10-K or 10-Q filing of the fact: supersession is counted among periodic reports
only. (`sec_gold.fact_asof` counts every form, so an 8-K recast or an S-1 that
re-files a number would otherwise end the 10-K vintage and leave nothing in force:
Microsoft FY2023 assets vanished after its 2024-12-04 8-K.) Where two in-force
facts for a tag differ, the most recent wins. One fiscal year end per `fyear`:
where a fiscal-year change or reverse merger leaves two, the later is kept (664
dropped as of 2026-10-01). `capx`, `dp`, `xint` and `xrd` are taken as absolute
values: S&P defines them as non-negative, and a negative filed value is a sign slip.

Components summed by FASB's calculation tree. Where the total is not filed, `dltt`
is `LongTermDebtNoncurrent` plus finance leases, or else the calc children of
`LongTermDebtNoncurrent` the filer tags (S&P DLTT includes capitalized leases);
the current-maturity helper `_dd1` and short-term borrowings `_np` likewise; `invt`
sums its net-of-reserve components and industry inventory lines (not gross
inventory and the LIFO reserve, which would double count). `cogs`, with no cost of
revenue filed, is SALE − XSGA − DP − OIADP: S&P (guide item 41) treats total
operating costs as COGS when no breakdown is reported, and OIADP = SALE − COGS −
XSGA − DP by S&P's definition; for lenders, interest expense plus loan-loss
provision (guide item 41). `ni` from income available to common adds back
preferred dividends; `ib` subtracts whichever discontinued-operations element is
filed; `epspx` is basic EPS less discontinued operations per share; `csho` falls
back to shares issued less treasury shares; `pstk` includes preferred carried with
its paid-in capital (banks). SALE and REVT take the filed total first, then ASC
606 contract revenue plus revenue not from contracts (contract revenue alone
omits GM Financial or Walmart membership income).

## Presentation rules

`data/reference/compustat_presentation_rules.csv`, applied by
`tools/export_compustat.py` to each state's governing 10-K (the latest annual
report among its in-force facts), using the face statements in
`sec_silver.pre_silver`:

- `zero`: an item missing from the facts is 0 when the filing presents the
  statement and no line on it is in the item's family: its tags, their FASB
  calculation descendants, or a label matching the rule (an `exclude_regex` keeps
  assets, note references and operating leases from counting as debt). S&P
  collects these items from the face statements, and CZ's predictors use them
  without filling zeros, so a firm with no debt line would otherwise drop out of
  every leverage signal. Applied to `dltt`, `dlc`, `mib`, `pstk`, `invt`, `dvc`,
  `dvp`, `dv`, `prstkc`, `sstk`, `dltis`, `dltr`; not to items commonly folded
  into an "other" line on the face and broken out in the notes (`xint`, `txp`,
  `ivst`: Apple's interest expense is a footnote figure). Each row records the
  items zeroed in `zeroed_items`.
- `refuse_tag`: `Revenues` is not SALE/REVT when the filing labels it as including
  other income, or when the filed `Revenues` equals a sales figure plus
  non-operating components filed for the same period
  (`compustat.revenues_include_nonoperating`). Not caught: a filer that files only
  the total (XOM 2022: 413,680 against 398,675 sales and other operating revenue).
- `add_if_label`: S&P SEQ = CEQ + PSTK and PSTK includes redeemable preferred
  (guide items 216, 130), while XBRL `StockholdersEquity` excludes temporary
  equity; temporary equity presented as preferred is added to `seq` and `pstk`
  (SPAC class A subject to redemption is common and is not).

Coverage of the first vintage of each fiscal year, before → after these rules
(as of 2026-10-01): `mib` 20% → 82%, `invt` 36% → 83%,
`dvc` 21% → 68%, `pstk` 29% → 61%, `dltt` 32% → 55%, `dlc` 28% → 55%, `cogs` 31% →
47%. Known gaps: debt tagged only with dimensions (Caterpillar, Ford, GM by
segment) is not in `fact_asof`; bank revenue where neither total nor interest
income is filed undimensioned (JPM); GE's principal pension plans are tagged apart
from its other pension plans (see Footnote items).

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
2026-10-01, all 80 archives: 11,465 of 12,013 reports within 1% of the PBO (95.4%),
and 96 more where the filer reported the funded status with its sign reversed (an
underfunded plan as a positive number), a sign error in that element rather than
in assets or PBO.

Coverage, as of 2026-10-01 (`notes_items_coverage.csv`): pensions 13,653 annual
reports of 1,736 companies, segments 80,349 segment-years of 4,429, customers 69,764
of 4,720, AOCI components 14,208 reports of 2,633. Footnote facts are sparse for
fiscal 2009–2010 (pensions 0 and 193 companies, segments 2 and 91) and reach
1,000–2,000 companies a year from 2012: the SEC phased in detailed footnote tagging
after each filer's first XBRL year.

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
