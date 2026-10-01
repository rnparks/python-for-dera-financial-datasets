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
