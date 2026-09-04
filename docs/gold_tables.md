# `sec_gold` — Gold Layer Reference

The gold layer is the query-facing top of the medallion pipeline: SEC DERA fundamentals for every company that has ever been an S&P 500, 400 or 600 constituent (membership dated where the history has been replayed), keyed by ticker, with a canonical-concept taxonomy and pre-computed peer statistics on top. Everything here is derived from `sec_silver` — rebuild it any time with `uv run dera build-gold`.

**Data coverage** (as of the 2026q2 load, figures dated 2026-09-04): filings from 2009-04-15 through 2026-06-30, 12.4M rows per display matview (1,701 companies that have ever been index constituents) and 97.9M in `fact_asof`.

For the whole database — including `sec_reference`, which holds the survivorship-free company and security spine — see [`schema_overview.md`](schema_overview.md).

---

## Object inventory

| Object | Kind | Rows | One-line description |
|---|---|---:|---|
| [`fact_asof`](#fact_asof) | matview | 97.9M | **Bitemporal facts, every vintage. The correct backtest source.** |
| [`tradable_financials`](#tradable_financials) | matview | 12.4M | Latest-restated facts, one row per fact, index membership dated |
| [`tradable_financials_pit`](#tradable_financials_pit) | matview | 12.4M | Earliest-sighting twin of the above |
| [`peer_stats`](#peer_stats) | matview | 480K | Cross-sectional scores at sector AND sub-industry, tagged by `peer_level`; population is the index of the time |
| [`share_class_shares`](#share_class_shares) | matview | 778K | **Per-share-class counts for 9,654 companies, delisted included. The market-cap denominator.** |
| [`canonical_concepts`](#canonical_concepts) | table | 15 | Research-meaningful metric definitions (revenue, capex, …) |
| [`concept_tag_map`](#concept_tag_map) | table | 38 | Priority-ordered XBRL tag resolution rules per concept |
| `concept_formula` | table | 6 | Derived concepts as linear combinations of other concepts |
| [`metric_aliases`](#metric_aliases) | table | 4 | Legacy display-name remap for `get_pit_financials` |
| [`get_canonical()`](#get_canonical) | function | — | Resolve (cik, concept, date) → one value: tags first, then formula |
| `resolve_direct()` | function | — | Tag-walk only, no formula. Operand resolver for derived concepts |
| `as_of_resolve_direct()` | function | — | Same, against `fact_asof` at a knowledge date |
| [`get_canonical_by_ticker()`](#get_canonical_by_ticker) | function | — | Ticker wrapper for `get_canonical` |
| [`latest_annual()`](#latest_annual) | function | — | Most recent annual value, fiscal-year-end aware, formula fallback |
| [`latest_annual_by_ticker()`](#latest_annual_by_ticker) | function | — | Ticker wrapper for `latest_annual` |
| [`company_snapshot()`](#company_snapshot) | function | — | One row per canonical concept for a ticker |
| [`get_pit_financials()`](#get_pit_financials) | function | — | Legacy: revenue/net-income history in $B by CIK |
| [`get_financials_by_ticker()`](#get_financials_by_ticker) | function | — | Legacy: ticker wrapper for `get_pit_financials` |
| `as_of_facts()` | function | — | Every fact for a company as it stood on a date |
| `as_of_canonical()` | function | — | One concept as of a date |
| [`as_of_latest_annual()`](#as_of_latest_annual) | function | — | Most recent annual value knowable on a date, formula fallback |
| `as_of_latest_annual_by_ticker()` | function | — | Ticker wrapper; resolves the ticker as of the same date, raises if it cannot |
| [`as_of_snapshot()`](#as_of_snapshot) | function | — | Every concept as of a date, keyed by CIK or by ticker |
| [`shares_outstanding_at()`](#shares_outstanding_at) | function | — | Single collapsed share count. NOT sufficient for multi-class market cap |
| [`share_classes_at()`](#share_classes_at) | function | — | Every share class for a company as of a date, one row per class |
| `norm_ticker()` | function | — | Ticker to stored form (`BRK.B` → `BRK-B`) |
| `fiscal_year_of()` | function | — | Peer-comparison year key for non-December filers |
| `shift_sessions()` | function | — | Move a date back N trading sessions; raises if none exists |

---

## Core semantics (read this first)

### `latest` vs. `pit` mode

Nearly everything in gold comes in two flavors, matching the dual ranking computed in `sec_silver.num_silver`:

- **`latest`** — the most recently restated value for each fact. Use for fundamental analysis and dashboards ("what do we now believe FY2022 revenue was").
- **`pit`** — the **earliest sighting of the fact in this dataset**. Coverage begins 2009-04-15 and registration statements backfill years of history, so this is not always "as originally filed": 27.8% of `rank_pit = 1` annual rows are prior-period comparatives, flagged by `is_original_disclosure`. Verified example: GE's FY2022 revenue exists as the original $76.5B (`pit`) and restated $29.1B (`latest`).

The matviews are split into a `latest` view and a `_pit` twin; the functions take a `p_mode` parameter, **defaulting to `'pit'`**. Handing restated figures to a caller who omitted the argument was judged the most damaging default available, so `'latest'` must be asked for explicitly.

**Neither mode is availability-correct.** Both carry no knowledge date, so a loop over historical dates against either will read facts filed after the date it simulates. Backtests use the `as_of_*` family, which has no default knowledge date.

### The `qtrs` convention

`qtrs` is the number of quarters a value covers, straight from SEC DERA:

- **`qtrs = 0`** — point-in-time balance-sheet snapshot (assets, equity, debt, cash).
- **`qtrs = 1`** — one quarter's flow (a 10-Q income-statement figure).
- **`qtrs = 4`** — trailing/full fiscal-year flow (a 10-K figure).

Income-statement and cash-flow analysis at annual grain should filter `qtrs = 4`; balance-sheet analysis should filter `qtrs = 0`. The `latest_annual()` family does this branching for you based on the concept's `fact_type`.

### Consolidated-only filtering

The matviews contain **only consolidated, parent-entity facts**: rows with non-null `segments` (business-segment breakdowns) or `coreg` (subsidiary co-registrants) are excluded upstream. You never need to re-apply this filter on gold objects. The one exception is `share_class_shares`, which reads the `ClassOfStock` axis on purpose.

### Fiscal years ≠ calendar years

Many large filers have non-December fiscal year ends (Apple → Sep, Microsoft → Jun, NVIDIA → Jan, Nike → May). A filter like `value_date = '2025-12-31' AND qtrs = 4` silently drops them all. Use `latest_annual()` / `company_snapshot()` for FY-aware lookups, or bucket with `sec_gold.fiscal_year_of(value_date)` as `peer_stats` does. Do NOT use `EXTRACT(YEAR FROM value_date)`: it pushes January year-ends such as NVIDIA and Walmart into the following calendar year, comparing eleven months against a peer's full year.

### How a derived concept is resolved

`gross_profit`, `free_cash_flow` and `total_debt` can come from a filed tag or from a formula over other concepts (`concept_formula`). Both the `latest_annual` family and the `as_of_*` family resolve them the same way:

1. Find the newest period at which any **direct** tag resolves.
2. Find the newest period at which the **formula** resolves — candidate periods are every period at which any operand exists, newest first, up to twelve, and the formula is evaluated at each until one succeeds. A period missing a required operand falls through to the next rather than ending the search.
3. **The newer period wins.** At the same period a filed figure beats a reconstruction.

Rule 3 matters: before it, Apple's `total_debt` resolved to a 2015 `LongTermDebt` row ($40.1B) while its 2026 balance sheet carried the components ($82.7B), because "direct always wins" was applied across periods. And before rule 2, `total_debt` — whose operands are both optional — never derived at all in `latest_annual`.

---

## Materialized views

### `fact_asof`

**The backtest source.** One row per (fact, filing), with every vintage retained — nothing is overwritten by a later restatement. 97.9M rows, 33 GB, covering the full company spine rather than only S&P 1500 constituents, so it carries no survivorship bias of its own.

Slice it with a half-open interval scan, which returns exactly one row per fact key with no window function at query time:

```sql
WHERE tradable_from <= T
  AND (superseded_tradable > T OR superseded_tradable IS NULL)
```

Availability columns: `known_at`, `tradable_from`, `superseded_tradable`, `vintage_seq`, `is_original_disclosure`. Provenance: `adsh`, `form`, `filed_date`. `value_date` is bounded to 2005 → now+1y because DERA publishes filer typos spanning 1980 to 2032.

Prefer the `as_of_*` function family over querying this directly — those take a mandatory knowledge date, so a look-ahead has to be written on purpose rather than by omission.

### `tradable_financials`

One row per **(company, XBRL tag, value date, period length, unit)** for every company that has ever had an interval in `sec_reference.index_membership` — the replayed S&P 500 history plus today's S&P 400 and 600 — holding the latest-restated value (`rank_latest = 1` in silver). Built from `sec_silver.num_silver` joined to `sec_reference.company`, `sec_reference.company_label`, the dated `sec_reference.company_ticker` and `sec_reference.index_membership`, both resolved against each fact's `tradable_from`. It does **not** use `sec_silver.ticker_map` or `sec_silver.universe_sp1500`.

| Column | Type | Description |
|---|---|---|
| `ticker` | text | Exchange ticker (class shares use hyphens: `BRK-B`) |
| `ticker_is_asof` | boolean | `true` only when an **observed** crosswalk interval (2018-12 onward) covers `tradable_from`. `false` means the label is inferred: the back-extended interval of a single-ticker history, or the company's best-known symbol where there is none |
| `company_name` | text | Company name as of the fact, via `sec_reference.company_label` |
| `index_name` | text | Index the company belonged to **as of `tradable_from`**: `SP500` from replayed history; `SP400`/`SP600` from today's snapshot at every date until their histories are replayed |
| `index_is_asof` | boolean | `true` when a membership interval covers `tradable_from`. `false` means the company was not a constituent then and `index_name` / GICS are labels from its latest membership |
| `gics_sector` | text | GICS sector as of `tradable_from` where the membership history has it (S&P 500), else the latest classification |
| `gics_sub_industry` | text | GICS sub-industry, same rule (the page carries it from 2016) |
| `known_at` | timestamptz | When the filing was accepted by EDGAR |
| `tradable_from` | date | First session on which the fact was actionable |
| `cik` | integer | SEC Central Index Key |
| `tag` | text | Raw XBRL tag, e.g. `NetIncomeLoss` |
| `metric` | text | Human-readable tag label (`tlabel` from the taxonomy) |
| `value_date` | date | Period end date the value refers to |
| `filed_date` | date | Date the filing carrying this value hit EDGAR |
| `qtrs` | integer | Period length in quarters (see [qtrs convention](#the-qtrs-convention)) |
| `uom` | text | Unit of measure, usually `USD`; per-share tags use `USD/share` |
| `value` | numeric | The reported value, in raw units (dollars, not $B) |
| `adsh` | text | Accession number of the source filing |

**Indexes** (six, all btree): `ticker`, `value_date`, `tag`, `cik`, `tradable_from`, `gics_sector`.

```sql
-- Microsoft's 20 most recent reported facts
SELECT metric, value_date, qtrs, value
FROM sec_gold.tradable_financials
WHERE ticker = 'MSFT'
ORDER BY value_date DESC
LIMIT 20;
```

### `tradable_financials_pit`

Identical columns and indexes to `tradable_financials`, but holds the **earliest sighting** of each fact (`rank_pit = 1`) rather than the latest restatement. It has no knowledge date, so it is **not** a backtest source on its own: a loop over historical dates against it will read facts filed after the date it simulates. It exists for callers that want one row per fact without restatements. Use `fact_asof` and the `as_of_*` family for anything backtested.

```sql
-- What did NVDA report for FY-end 2023-01-29, as first seen in the dataset?
SELECT metric, value_date, filed_date, value
FROM sec_gold.tradable_financials_pit
WHERE ticker = 'NVDA' AND value_date = '2023-01-29' AND qtrs = 4;
```

### `peer_stats`

Pre-computed cross-sectional scores: one row per **(company, canonical concept, fiscal year, peer level)**. Sourced from `tradable_financials` (latest-restated values), **restricted to facts whose company was an index constituent when the fact became actionable** (`index_is_asof`). For the S&P 500 that is the replayed history, so a FY2012 cross-section scores 2012's members and not today's; for the S&P 400 and 600 it is today's list at every year until their histories are replayed. Each row carries `index_name`.

**Two peer levels, tagged by `peer_level`.** Sub-industry alone was too granular — only 106 of 156 groups clear the five-member threshold, and the threshold *deletes* a thin group rather than degrading it, so companies vanished with nothing in the output saying so. Both levels are computed:

| `peer_level` | Groups | Companies scored |
|---|---:|---:|
| `sector` | 11 | 1,692 CIKs across all fiscal years |
| `sub_industry` | 106 | fewer, groups under five members dropped |

Sector is the sounder default. The standard error of an estimated standard deviation is about σ/√(2(n−1)), so at the sub-industry median of seven companies the z-score denominator is itself uncertain by nearly 30%, against roughly 10% at sector's thinnest group.

Fiscal year is bucketed by `sec_gold.fiscal_year_of(value_date)`, **not** `EXTRACT(YEAR FROM value_date)` — see [Fiscal years ≠ calendar years](#fiscal-years--calendar-years).

S&P 500 revenue coverage by fiscal year, members of the time: 457 companies in FY2009, 476 in FY2012, 473 in FY2015, 499 in FY2024 (of roughly 500 resolved members each year). Before dated membership the FY2012 panel was today's surviving constituents only; before the pre-2018 revenue tags were mapped, FY2015 covered 628 of the whole tracked population.

| Column | Type | Description |
|---|---|---|
| `cik` | integer | SEC Central Index Key |
| `ticker` | text | Exchange ticker |
| `index_name` | text | Index the company belonged to when the fact became actionable |
| `gics_sector` | text | GICS sector as of the fact (11 values) |
| `gics_sub_industry` | text | GICS sub-industry as of the fact |
| `peer_level` | text | `sector` or `sub_industry` — **which grouping this row scores against** |
| `peer_group` | text | The actual group value `peer_level` selects; the composite indexes are keyed on it |
| `tradable_from` | date | Availability of the underlying fact |
| `concept` | text | Canonical concept (FK to `canonical_concepts`) |
| `fact_type` | text | `flow` or `balance` (derived concepts are resolved and included) |
| `fiscal_year` | integer | Peer-comparison year from `fiscal_year_of(value_date)` |
| `value_date` | date | Actual period end date behind the bucketed year |
| `value` | numeric | Resolved value (sign-adjusted, best-priority tag) |
| `peer_count` | bigint | Companies in the (concept, year, group) |
| `peer_mean` | numeric | Group mean |
| `peer_stddev` | numeric | Group sample standard deviation |
| `peer_min` / `peer_max` | numeric | Group extremes |
| `zscore` | numeric | `(value − peer_mean) / peer_stddev`; NULL if stddev is 0 |
| `peer_percentile` | numeric | Rank within the group; robust to the size skew that makes a raw-dollar z of +4 mean "much bigger than peers" |

**Indexes**: `(ticker)`; `(cik)`; `(index_name, fiscal_year)`; `(peer_level, concept, fiscal_year)`; `(peer_level, peer_group, fiscal_year, concept)`. Note `peer_level` leads both composite peer indexes — a query filtered only on `(concept, fiscal_year)` will not use them.

> **Not availability-correct.** Built from restated values, with peer moments computed over the finished panel, so both the inputs and the statistics know the future. The *population* of each cross-section is now point-in-time (who was in the index when the fact became actionable); the *values* are not. This is a dashboard and screening artifact. Anything backtested should read `fact_asof` and build its own cross-section.

```sql
-- NVDA revenue vs. semiconductor peers
SELECT fiscal_year, value, zscore, peer_count
FROM sec_gold.peer_stats
WHERE ticker = 'NVDA' AND concept = 'revenue' AND peer_level = 'sub_industry'
ORDER BY fiscal_year DESC;

-- Most extreme net-income outliers within sector, FY2025
SELECT ticker, gics_sector, zscore
FROM sec_gold.peer_stats
WHERE concept = 'net_income' AND fiscal_year = 2025 AND peer_level = 'sector'
ORDER BY zscore DESC
LIMIT 20;
```

### `share_class_shares`

**The market-cap denominator.** One row per (company, share class, period, vintage, source tag): 777,501 rows across 9,654 companies, delisted ones included; 482 of today's 500 S&P 500 constituents are covered, 61 of them through cover-page mappings. A class appears in one of two ways:

- **Mapped.** The issuer has rows in `sec_reference.share_class` and the class label matches the `ClassOfStock` member exactly (`method = 'mapped_class'`). 66 issuers are mapped: 9 by hand and 57 from their 10-K cover pages via `tools/fetch_cover_page_classes.py`, every row citing its filing.
- **Inferred single-class.** The issuer has no mapping and has **never reported share counts for two `ClassOfStock` members** on the three point-in-time share-count tags (`method = 'inferred_single'`). Decided from the filings, so preferreds, baby bonds, ADR lines and delistings do not matter: Bank of America with its seventeen tickers is single-class; Meta with its unlisted Class B is not, and needs its mapping. An issuer whose only class member is its sole class (Bunge files `ClassOfStock=CommonStock` and nothing undimensioned) is inferred from that member's rows. The price ticker is the company's primary line as of the fact.

Two earlier rules were wrong in opposite directions: "exactly one ticker current today" excluded every company that had delisted, and "never held two tickers at once" excluded every company with a listed preferred while quietly admitting dual-class issuers whose second class is unlisted — pricing Visa's consolidated count at the Class A price although its Class B does not convert 1:1.

| Column | Description |
|---|---|
| `class_label` | The `ClassOfStock` member, or `(single class)` |
| `price_ticker` | The ticker whose price applies: the class's own, the listed class an unlisted one converts into, or — for inferred rows — the ticker held on `tradable_from` |
| `price_ticker_is_asof` | `TRUE` for mapped rows and for inferred rows whose ticker an **observed** crosswalk interval covers on `tradable_from`; `FALSE` (348,705 rows, all before 2018-12) means `price_ticker` is inferred: a back-extended single-ticker history or the company's best-known symbol |
| `is_unlisted_class`, `conversion_ratio` | An unlisted class priced through a listed one, and at what ratio |
| `shares`, `value_date`, `source_tag`, `rung` | The count, its period, the tag it came from, and the tag's preference rank (1 best) |
| `known_at`, `tradable_from`, `superseded_tradable`, `vintage_seq` | The usual availability interval, inherited from `num_silver` per class |
| `method`, `mapping_source`, `adsh`, `company_name` | Provenance |

---

## Tables

### `canonical_concepts`

The research taxonomy: **15 concepts** that mean the same thing across companies regardless of which XBRL tag each company files. Three of them (`cost_of_revenue`, `debt_current`, `debt_noncurrent`) exist mainly as operands for `concept_formula`. `fact_type` drives the `qtrs` branching in `latest_annual()` (`flow` → `qtrs = 4`, `balance` → `qtrs = 0`). Derived concepts are computed in the database through `concept_formula`; see [How a derived concept is resolved](#how-a-derived-concept-is-resolved).

| Concept | Display name | Fact type | UoM | Description |
|---|---|---|---|---|
| `revenue` | Total Revenue | flow | USD | Top-line revenue for the period |
| `gross_profit` | Gross Profit | flow | USD | Revenue minus cost of goods sold |
| `operating_income` | Operating Income | flow | USD | Profit from core operations before tax/interest |
| `net_income` | Net Income | flow | USD | Bottom-line profit attributable to shareholders |
| `eps_diluted` | Diluted EPS | flow | USD/share | Diluted earnings per common share |
| `cash` | Cash and Equivalents | balance | USD | Cash, equivalents and (for non-banks) short-term investments |
| `total_assets` | Total Assets | balance | USD | Balance sheet total assets |
| `total_equity` | Total Equity | balance | USD | Stockholders equity (incl. noncontrolling interest when available) |
| `total_debt` | Total Debt | balance | USD | Total interest-bearing debt: a combined tag, else the sum of the two components |
| `operating_cash_flow` | Cash from Operations | flow | USD | Net cash provided by operating activities |
| `capex` | Capital Expenditures | flow | USD | Payments to acquire property, plant and equipment |
| `free_cash_flow` | Free Cash Flow | derived | USD | Operating cash flow minus capex |
| `cost_of_revenue` | Cost of Revenue | flow | USD | Operand for `gross_profit` |
| `debt_noncurrent` | Long-Term Debt | balance | USD | Operand for `total_debt` |
| `debt_current` | Current Debt | balance | USD | Operand for `total_debt` |

### `concept_tag_map`

The resolution rules that turn a concept into an actual XBRL tag, walked in order by `get_canonical()` and `latest_annual()`:

1. **Industry-specific rows first** — a row with a non-empty `sic_prefix` matching the company's SIC code (e.g. `60` = banks) beats every generic row.
2. **Then by `priority`** ascending (1 = try first).
3. The first tag with a non-null value for the requested (cik, date, qtrs, mode) wins; `value` is multiplied by `sign_multiplier` (currently `+1` everywhere).

| Concept | Pri | SIC | Tag | Notes |
|---|---:|---|---|---|
| `revenue` | 1 | any | `RevenueFromContractWithCustomerExcludingAssessedTax` | ASC 606 standard, most non-financial issuers |
| `revenue` | 2 | any | `Revenues` | Pre-ASC 606 fallback; some financials (BAC, C, PNC) |
| `revenue` | 3 | any | `RevenuesNetOfInterestExpense` | Large-bank headline revenue (JPM, WFC) |
| `revenue` | 4 | any | `RevenueFromContractWithCustomerIncludingAssessedTax` | ASC 606 variant incl. sales taxes |
| `revenue` | 5 | any | `SalesRevenueNet` | Pre-2018 total sales; 470 tracked issuers used it for FY2015 |
| `revenue` | 6 | any | `RealEstateRevenueNet` | REIT rental revenue total |
| `revenue` | 7–8 | any | `SalesRevenueGoodsNet`, `SalesRevenueServicesNet` | Pre-2018 components; safe only while no issuer files both without a total (check 37 asserts it) |
| `revenue` | 1 | 60 | `Revenues` | Some banks file plain Revenues |
| `revenue` | 2 | 60 | `RevenuesNetOfInterestExpense` | Large-bank headline revenue |
| `revenue` | 3 | 60 | `InterestAndDividendIncomeOperating` | Fallback: gross interest income |
| `revenue` | 1–2 | 49 | `RegulatedAndUnregulatedOperatingRevenue`, `Revenues` | Regulated utilities (NextEra and 10 others) |
| `gross_profit` | 1 | any | `GrossProfit` | Companies that file a gross-profit line |
| `operating_income` | 1 | any | `OperatingIncomeLoss` | Near-universal for non-financials |
| `net_income` | 1 | any | `NetIncomeLoss` | Incl. noncontrolling interest |
| `net_income` | 2 | any | `NetIncomeLossAvailableToCommonStockholdersBasic` | "Available to common" filers |
| `eps_diluted` | 1 | any | `EarningsPerShareDiluted` | Near-universal |
| `cash` | 1 | any | `CashAndCashEquivalentsAtCarryingValue` | Standard non-bank cash line |
| `cash` | 2 | any | `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` | ASC 230 total incl. restricted |
| `cash` | 3 | any | `Cash` | Legacy tag, small population |
| `cash` | 1 | 60 | `CashAndDueFromBanks` | Primary bank cash line |
| `cash` | 2 | 60 | `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` | Bank fallback |
| `total_assets` | 1 | any | `Assets` | Near-universal |
| `total_equity` | 1 | any | `StockholdersEquity` | Most common equity tag |
| `total_equity` | 2 | any | `StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest` | Consolidated groups w/ minority interest |
| `total_debt` | 1 | any | `DebtLongtermAndShorttermCombinedAmount` | Cleanest roll-up, few filers |
| `total_debt` | 2 | any | `LongTermDebt` | Older single-tag usage |
| `capex` | 1 | any | `PaymentsToAcquirePropertyPlantAndEquipment` | Most common capex tag |
| `capex` | 2 | any | `PaymentsToAcquireProductiveAssets` | Industrials/utilities fallback |
| `cost_of_revenue` | 1–2 | any | `CostOfGoodsAndServicesSold`, `CostOfRevenue` | Operands for the `gross_profit` formula |
| `debt_noncurrent` | 1–2 | any | `LongTermDebtNoncurrent`, `LongTermDebtAndCapitalLeaseObligations` | Operand for `total_debt` |
| `debt_current` | 1–3 | any | `LongTermDebtCurrent`, `…Current`, `DebtCurrent` | Operand for `total_debt` |
| `operating_cash_flow` | 1 | any | `NetCashProvidedByUsedInOperatingActivities` | Near-universal |

Add coverage for a new tag with a plain `INSERT` — no function changes needed. `concept_tag_map` holds 38 rows.

**Known gaps** (tracked in `features.md`): a few hundred issuers (notably NVDA capex) use custom extension tags not mapped here.

### `metric_aliases`

Legacy 4-row display-name remap kept for backward compatibility with `get_pit_financials()`. New work should use `canonical_concepts` instead.

| Tag | Display name |
|---|---|
| `Revenues` | Total Revenue |
| `RevenueFromContractWithCustomerExcludingAssessedTax` | Total Revenue |
| `NetIncomeLoss` | Net Income |
| `NetIncomeLossAvailableToCommonStockholdersBasic` | Net Income |

---

## Functions

### `get_canonical()`

```sql
sec_gold.get_canonical(
    p_cik        INTEGER,
    p_concept    TEXT,
    p_value_date DATE,
    p_qtrs       INTEGER DEFAULT 4,
    p_mode       TEXT    DEFAULT 'pit'      -- 'pit' | 'latest'
) RETURNS NUMERIC
```

Resolves one concept to one value for an exact `(cik, value_date, qtrs)` by walking `concept_tag_map` (industry-specific rules first, then priority), then `concept_formula` if no tag resolves. Returns NULL if neither does, or if a required operand is missing. Because it requires the exact period-end date, prefer `latest_annual()` unless you already know the company's fiscal calendar.

```sql
SELECT sec_gold.get_canonical(320193, 'revenue', '2025-09-30');  -- AAPL FY2025
```

### `get_canonical_by_ticker()`

Same signature and behavior with a `p_ticker TEXT` first argument, resolved through `sec_silver.ticker_map` (current-state, survivorship-biased; a delisted company's ticker does not resolve).

```sql
SELECT sec_gold.get_canonical_by_ticker('AAPL', 'revenue', '2025-09-30');
```

### `latest_annual()`

```sql
sec_gold.latest_annual(
    p_cik     INTEGER,
    p_concept TEXT,
    p_mode    TEXT DEFAULT 'pit'
) RETURNS TABLE (value_date DATE, filed_date DATE, value NUMERIC, tag TEXT)
```

The fiscal-year-aware lookup: returns the **most recent** observation for a concept regardless of when the company's fiscal year ends. Branches on the concept's `fact_type`:

- `flow` concepts → most recent `qtrs = 4` (annual total, i.e. the latest 10-K figure).
- `balance` concepts → most recent `qtrs = 0` (point-in-time snapshot — note this is the latest **quarterly** balance sheet, which may be newer than the last 10-K).

Derived concepts follow [the resolution rules above](#how-a-derived-concept-is-resolved); a derived row carries a NULL `tag`. Returns the winning tag otherwise so you can audit which mapping rule fired.

```sql
-- JPM FY2025 net income — a 2026q1-filed 10-K figure
SELECT * FROM sec_gold.latest_annual(19617, 'net_income');
--  value_date | filed_date  |    value    | tag
--  2025-12-31 | 2026-02-13  | 57000000000 | NetIncomeLoss  (≈ $57.0B)
```

### `latest_annual_by_ticker()`

Ticker wrapper for `latest_annual()`, same return shape, resolved through `sec_silver.ticker_map`.

```sql
SELECT * FROM sec_gold.latest_annual_by_ticker('NKE', 'revenue');  -- May FYE handled
```

### `company_snapshot()`

```sql
sec_gold.company_snapshot(
    p_ticker TEXT,
    p_mode   TEXT DEFAULT 'pit'
) RETURNS TABLE (concept TEXT, display_name TEXT, fact_type TEXT,
                 value_date DATE, value NUMERIC, tag TEXT)
```

One row per canonical concept (**15 rows**), each resolved via `latest_annual_by_ticker()`. Derived concepts are included and computed. The one-call company overview. Flows land on the last fiscal-year end; balances land on the most recent quarterly balance-sheet date, so the two groups can carry different `value_date`s — that is expected.

```sql
SELECT * FROM sec_gold.company_snapshot('AAPL');
--  concept             | value_date | value    | tag
--  revenue             | 2025-09-30 | $416.2B  | RevenueFromContractWithCustomer…
--  net_income          | 2025-09-30 | $112.0B  | NetIncomeLoss
--  total_assets        | 2026-03-31 | …        | Assets           ← newer 10-Q date
--  total_debt          | 2026-03-31 | $82.7B   | (derived: debt_noncurrent + debt_current)
--  free_cash_flow      | 2025-09-30 | $98.8B   | (derived: operating_cash_flow − capex)
--  ... (15 rows)
```

### `as_of_latest_annual()`

```sql
sec_gold.as_of_latest_annual(
    p_cik             INTEGER,
    p_concept         TEXT,
    p_asof            DATE,             -- required: no default
    p_buffer_sessions INTEGER DEFAULT 0
) RETURNS TABLE (value_date DATE, tradable_from DATE, value NUMERIC, tag TEXT)
```

`latest_annual()` against `fact_asof` with the availability predicate: the most recent annual (or balance-sheet) observation that was actionable on `p_asof`, resolved through the same direct-then-formula rules with every operand filtered by the same knowledge date. `p_buffer_sessions` moves the knowledge date back N trading sessions.

### `as_of_snapshot()`

```sql
sec_gold.as_of_snapshot(p_cik    INTEGER, p_asof DATE, p_buffer_sessions INTEGER DEFAULT 0)
sec_gold.as_of_snapshot(p_ticker TEXT,    p_asof DATE, p_buffer_sessions INTEGER DEFAULT 0)
  RETURNS TABLE (concept TEXT, display_name TEXT, fact_type TEXT,
                 value_date DATE, tradable_from DATE, value NUMERIC, tag TEXT)
```

Every canonical concept as it was knowable on `p_asof`. The ticker form resolves the CIK **as of the same date** through `sec_reference.cik_at_strict()` and **raises** if the crosswalk cannot resolve it (observed from 2018-12, extended back to the first filing for single-ticker histories); the CIK form works at any date. The knowledge date has no default.

```sql
SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2022-06-30');
SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2015-06-30');   -- resolves: Apple has only ever been AAPL
SELECT * FROM sec_gold.as_of_snapshot(1326801, DATE '2015-06-30'); -- Meta was FB then; the ticker form raises, the CIK form works
```

### `shares_outstanding_at()`

```sql
sec_gold.shares_outstanding_at(p_cik INTEGER, p_asof DATE, p_buffer_sessions INTEGER DEFAULT 0)
  RETURNS TABLE (shares NUMERIC, value_date DATE, tradable_from DATE, source_tag TEXT, method TEXT)
```

One collapsed share count knowable on the date, by a tag ladder (`EntityCommonStockSharesOutstanding`, `CommonStockSharesOutstanding`, `CommonStockSharesIssued`, then weighted averages) with mapped share-class summation. An instant count within 400 days of the newest available period beats a period average at the newest period; when only an average is that recent, `source_tag` says so (130 of 1,573 tracked companies today). **Not sufficient for market cap on a multi-class issuer**; use `share_classes_at()`.

### `share_classes_at()`

```sql
sec_gold.share_classes_at(p_cik INTEGER, p_asof DATE, p_buffer_sessions INTEGER DEFAULT 0)
  RETURNS TABLE (class_label TEXT, price_ticker TEXT, is_unlisted_class BOOLEAN,
                 conversion_ratio NUMERIC, shares NUMERIC, value_date DATE,
                 tradable_from DATE, source_tag TEXT, method TEXT,
                 price_ticker_is_asof BOOLEAN)
```

One row per share class as knowable on the date: the newest period, then the better tag, then the newest vintage. Market cap is `SUM(shares * price_of(price_ticker))`; a class missing here means no mapping exists and market cap is incomplete.

### `get_pit_financials()`

```sql
sec_gold.get_pit_financials(p_cik INTEGER)
RETURNS TABLE (value_date DATE, filed_date DATE, metric TEXT, value_billions NUMERIC)
```

**Legacy.** Annual (`qtrs = 4`) revenue and net-income history from the **pit** matview, restricted to the 4 tags in `metric_aliases`, values pre-scaled to billions. Kept for backward compatibility; prefer the canonical family for new work.

### `get_financials_by_ticker()`

```sql
sec_gold.get_financials_by_ticker(p_ticker TEXT)
RETURNS TABLE (value_date DATE, filed_date DATE, metric TEXT, value_billions NUMERIC)
```

**Legacy.** Ticker wrapper for `get_pit_financials()`. Raises an exception if the ticker is not in `sec_silver.ticker_map`.

---

## Caveats and data quirks

- **Stray `value_date`s.** The matviews span 1980-07-31 → 2032-03-31. Old dates are prior-period comparatives re-filed in modern filings; future dates are filer typos that SEC publishes as-is. Bound `value_date` in analyses that aggregate by date.
- **Index membership is dated for the S&P 500 only.** The two `tradable_financials` matviews and `peer_stats` draw their population from `sec_reference.index_membership`: replayed monthly Wikipedia history for the S&P 500 (840 companies since 2008, 40 early tickers unresolved and listed), but today's list at every date for the S&P 400 and 600 until their histories are replayed. Historical analyses restricted to those two indexes still carry survivorship bias, and `index_membership.source` says which rows do. `fact_asof`, `share_class_shares` and everything in `sec_reference` cover the full spine.
- **Per-share vs. dollar units.** `eps_diluted` is `USD/share`; don't scale it by 1e9 alongside the dollar concepts. Check `uom` when working with raw tags.
- **`total_debt` is a roll-up.** Only two tags resolve it directly; otherwise `concept_formula` sums `debt_noncurrent + debt_current`. `LongTermDebtNoncurrent` was once priority 3 here and silently understated the figure by excluding the current portion; it now sits on `debt_noncurrent` where it belongs.
- **Z-scores are raw-value scores.** `peer_stats` scores raw dollar values, so it mixes company size with performance; a z of +4 on revenue mostly means "much bigger than peers," not "growing faster." `peer_percentile` is robust to that skew. Both degrade in thin groups, which is why `peer_level = 'sector'` is the sounder default.
- **Dual-class issuers need a mapping.** Across the spine roughly 2,100 companies have reported share counts for two or more `ClassOfStock` members; 66 are mapped, 57 of them S&P 500 issuers derived from their cover pages. The rest have no rows in `share_class_shares`, by design (an unmapped class yields nothing rather than a wrong sum). Six S&P 500 covers say only "Common Stock" against A/B members and are reported by the tool for a hand decision; unlisted classes (Meta's B, Nike's A, Visa's B and C) are never mapped automatically because the conversion ratio must be cited, so those issuers' market caps are partial and flagged by `share_classes_at`.
- **Ticker collisions.** `ticker_map` keeps the first CIK seen per ticker; a handful of ambiguous tickers may resolve to an unexpected issuer. The `as_of_*` family avoids this by resolving through the dated crosswalk.

## Rebuilding and refreshing

```bash
uv run dera build-gold                 # full DDL rebuild (drops + recreates sec_gold), ~32 min
uv run dera build-gold --refresh-only  # REFRESH all five matviews, in order
uv run dera rebuild-reference          # after a crosswalk change: spine, security model, then gold
```

Notes:

- `build-silver` **drops gold's matviews** via `DROP SCHEMA sec_silver CASCADE`, and so does a spine rebuild (they depend on `sec_reference.company`), so a full gold rebuild (not `--refresh-only`) is required after either.
- `build-silver` runs `ANALYZE` on `sec_silver.num_silver` and `sub_silver` at the end of the build. Skipping it made the gold matview joins plan against a statistics-less 181M-row table (observed: 9 hours instead of ~1 minute).
- `--refresh-only` refreshes all five matviews in dependency order, `peer_stats` last.
- The functions can be re-applied one file at a time with `run_sql_file`; each drops its previous signature first.

## Derived concepts

`sec_gold.concept_formula` defines a derived concept as a linear combination of other concepts:

| Concept | Formula | Why |
|---|---|---|
| `gross_profit` | `revenue - cost_of_revenue` | Recovers issuers that file cost but no gross profit line |
| `free_cash_flow` | `operating_cash_flow - capex` | No filer tags free cash flow |
| `total_debt` | `debt_noncurrent + debt_current` | Fires only when no combined debt tag resolves |

Two rules make this safe.

**One level deep.** Operands must resolve from tags, never from another formula. This is enforced by construction rather than convention: the formula branch calls `resolve_direct()`, which knows nothing about formulas, so recursion is impossible.

**`required` says what a missing operand means.** When true, the result is NULL without it, because gross profit from revenue alone is not gross profit. When false, the operand is treated as zero, because a company reporting no capex still has a free cash flow. At least one operand must resolve either way, so a company with no debt at all yields NULL rather than a confident zero.

### Coverage ceilings are sometimes structural

Banks, REITs and insurers do not report a gross profit line at all, so `gross_profit` cannot reach the whole universe and no amount of tag work will close it. Any screen using gross margin should say so rather than quietly dropping half the book.

## Multi-class issuers and market cap

Market cap for a multi-class issuer is the sum over classes of shares times **that class's** price. It cannot be computed from a single collapsed share count: GOOGL and GOOG trade a percent or two apart, but BRK.A is roughly 1,500 times BRK.B. `shares_outstanding_at()` returns one number and is explicitly not sufficient here. Use `share_class_shares` / `share_classes_at()`.

### Why the class filter is an allowlist, not a pattern match

The obvious approach is to match the `ClassOfStock` axis and sum what matches. That was tried and it is wrong. Against issuers publishing both a consolidated total and clean per-class rows, summing the classes disagreed with the total in **312 of 1,033 cases**, because the axis is free text whose members routinely overlap one another:

| Issuer | Members filed | Effect of summing |
|---|---|---|
| Symbotic | ClassA, V1, V3 **and** V1AndV3 | 82% too high |
| Kodiak | ClassA **and** ClassANotSubjectToRedemption | subset counted twice |
| Xanadu | ten members including a literal `TotalCommonShares` | nonsense |

No regex separates those from genuine classes. So a class contributes only if explicitly mapped in `sec_reference.share_class`. An unmapped member yields nothing, which makes those failures structurally impossible rather than filtered against.

### Three states a class can be in

- **Listed.** `ticker` set; price it directly. Only listed classes become `sec_reference.security` rows and universe members.
- **Unlisted but real equity.** `ticker` NULL, `prices_with_ticker` set. Alphabet Class B is 849M shares with no ticker; dropping it understates market cap by roughly 7%, pricing it at zero is worse. It is priced at the class it converts into, with the ratio cited rather than assumed.
- **Excluded.** Not common equity, or a duplicate expression of another row. Berkshire publishes the whole company twice, in A-equivalent and B-equivalent units at exactly 1,500 to 1; counting both double counts the company.

### Provenance

Every mapping row carries `source` and `source_note`. Filing-sourced and vendor-sourced rows can coexist and be audited separately, and a row can be re-derived without touching the rest. Single-class issuers are inferred deterministically and need no mapping at all.

## Source files

| File | Creates |
|---|---|
| `010_schema.sql` | drops and recreates the `sec_gold` schema |
| `015_ticker_normalize.sql` | `norm_ticker()` |
| `016_fiscal_year.sql` | `fiscal_year_of()` |
| `017_shift_sessions.sql` | `shift_sessions()` |
| `020_metric_aliases.sql` | `metric_aliases` |
| `030_tradable_financials.sql` | `tradable_financials`, `tradable_financials_pit` |
| `035_fact_asof.sql` | `fact_asof` |
| `040_helper_functions.sql` | `get_pit_financials()`, `get_financials_by_ticker()` |
| `050_canonical_concepts.sql` | `canonical_concepts`, `concept_tag_map`, `concept_formula` |
| `055_shares_outstanding.sql` | `shares_outstanding_at()` |
| `056_share_class_shares.sql` | `share_class_shares`, `share_classes_at()` |
| `060_canonical_function.sql` | `resolve_direct()`, `get_canonical()`, `get_canonical_by_ticker()` |
| `065_asof_functions.sql` | the `as_of_*` functions, including both `as_of_snapshot` overloads |
| `070_fiscal_year_views.sql` | `latest_annual()`, `latest_annual_by_ticker()`, `company_snapshot()` |
| `080_peer_stats.sql` | `peer_stats` (resolves derived concepts too) |

Files run in lexical order within the directory, so the numeric prefix is
load-bearing. `065_asof_functions.sql` sits after `050` because it resolves
canonical concepts and `concept_tag_map` does not exist before then.
