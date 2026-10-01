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

## Not mapped

`spi` (special items: no single element), `emp` (employees: a cover-page
disclosure outside the financial statements), `fatb`/`fatl`/`ppenb`/`ppenls` (PP&E
by class), `ob` (order backlog), `fopt` and `wcapch` (pre-1988 statement of
changes items), `cshrc`, `ibcom`. Descriptors (`fyear`, `sich`, `datadate`) and
prices (`prcc_c`, `prcc_f`) come from the filing index and the price panel, not
from the map.
