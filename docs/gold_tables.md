# `sec_gold` — Gold Layer Reference

The gold layer is the query-facing top of the medallion pipeline: SEC DERA fundamentals filtered to the S&P 1500 tradable universe, keyed by ticker, with a canonical-concept taxonomy and pre-computed peer statistics on top. Everything here is derived from `sec_silver` — rebuild it any time with `uv run dera build-gold`.

**Data coverage** (as of the 2026q1 load): filings from 2009-04-15 through 2026-03-31, 1,496 tickers, ~11.3M rows per matview.

---

## Object inventory

| Object | Kind | Rows | One-line description |
|---|---|---:|---|
| [`fact_asof`](#fact_asof) | matview | 98M | **Bitemporal facts, every vintage. The correct backtest source.** |
| [`tradable_financials`](#tradable_financials) | matview | 11.8M | Latest-restated facts, one row per fact |
| [`tradable_financials_pit`](#tradable_financials_pit) | matview | 11.8M | As-first-seen twin of the above |
| [`peer_stats`](#peer_stats) | matview | ~220K | Cross-sectional scores at sector AND sub-industry, tagged by `peer_level` |
| [`canonical_concepts`](#canonical_concepts) | table | 12 | Research-meaningful metric definitions (revenue, capex, …) |
| [`concept_tag_map`](#concept_tag_map) | table | ~40 | Priority-ordered XBRL tag resolution rules per concept |
| `concept_formula` | table | 6 | Derived concepts as linear combinations of other concepts |
| [`metric_aliases`](#metric_aliases) | table | 4 | Legacy display-name remap for `get_pit_financials` |
| [`get_canonical()`](#get_canonical) | function | — | Resolve (cik, concept, date) → one value: tags first, then formula |
| `resolve_direct()` | function | — | Tag-walk only, no formula. Operand resolver for derived concepts |
| `as_of_resolve_direct()` | function | — | Same, against `fact_asof` at a knowledge date |
| [`get_canonical_by_ticker()`](#get_canonical_by_ticker) | function | — | Ticker wrapper for `get_canonical` |
| [`latest_annual()`](#latest_annual) | function | — | Most recent annual value, fiscal-year-end aware |
| [`latest_annual_by_ticker()`](#latest_annual_by_ticker) | function | — | Ticker wrapper for `latest_annual` |
| [`company_snapshot()`](#company_snapshot) | function | — | One row per canonical concept for a ticker |
| [`get_pit_financials()`](#get_pit_financials) | function | — | Legacy: revenue/net-income history in $B by CIK |
| [`get_financials_by_ticker()`](#get_financials_by_ticker) | function | — | Legacy: ticker wrapper for `get_pit_financials` |
| `as_of_facts()` | function | — | Every fact for a company as it stood on a date |
| `as_of_canonical()` | function | — | One concept as of a date |
| `as_of_latest_annual()` | function | — | Most recent annual value knowable on a date |
| `as_of_latest_annual_by_ticker()` | function | — | Ticker wrapper, resolves the ticker as of the same date |
| `as_of_snapshot()` | function | — | Every concept for a ticker as of a date |
| `shares_outstanding_at()` | function | — | Share count with share-class summation |
| `norm_ticker()` | function | — | Ticker to stored form (`BRK.B` → `BRK-B`) |
| `fiscal_year_of()` | function | — | Peer-comparison year key for non-December filers |
| `shift_sessions()` | function | — | Move a date back N trading sessions |

---

## Core semantics (read this first)

### `latest` vs. `pit` mode

Nearly everything in gold comes in two flavors, matching the dual ranking computed in `sec_silver.num_silver`:

- **`latest`** — the most recently restated value for each fact. Use for fundamental analysis and dashboards ("what do we now believe FY2022 revenue was").
- **`pit`** (point-in-time) — the value as it was **first reported**, with no look-ahead. Use for backtesting ("what did the market know on the day of filing"). Verified example: GE's FY2022 revenue exists as both the original $76.5B (`pit`) and restated $29.1B (`latest`).

The matviews are split into a `latest` view and a `_pit` twin; the functions take a `p_mode` parameter (default `'latest'`).

### The `qtrs` convention

`qtrs` is the number of quarters a value covers, straight from SEC DERA:

- **`qtrs = 0`** — point-in-time balance-sheet snapshot (assets, equity, debt, cash).
- **`qtrs = 1`** — one quarter's flow (a 10-Q income-statement figure).
- **`qtrs = 4`** — trailing/full fiscal-year flow (a 10-K figure).

Income-statement and cash-flow analysis at annual grain should filter `qtrs = 4`; balance-sheet analysis should filter `qtrs = 0`. The `latest_annual()` family does this branching for you based on the concept's `fact_type`.

### Consolidated-only filtering

The matviews contain **only consolidated, parent-entity facts**: rows with non-null `segments` (business-segment breakdowns) or `coreg` (subsidiary co-registrants) are excluded upstream. You never need to re-apply this filter on gold objects.

### Fiscal years ≠ calendar years

Many large filers have non-December fiscal year ends (Apple → Sep, Microsoft → Jun, NVIDIA → Jan, Nike → May). A filter like `value_date = '2025-12-31' AND qtrs = 4` silently drops them all. Use `latest_annual()` / `company_snapshot()` for FY-aware lookups, or bucket with `sec_gold.fiscal_year_of(value_date)` as `peer_stats` does. Do NOT use `EXTRACT(YEAR FROM value_date)`: it pushes January year-ends such as NVIDIA and Walmart into the following calendar year, comparing eleven months against a peer's full year.

---

## Materialized views

### `tradable_financials`

One row per **(company, XBRL tag, value date, period length, unit)** for every S&P 1500 constituent, holding the latest-restated value (`rank_latest = 1` in silver). Built by joining `sec_silver.universe_sp1500` → `sec_silver.ticker_map` → `sec_silver.num_silver`.

| Column | Type | Description |
|---|---|---|
| `ticker` | text | Exchange ticker (class shares use hyphens: `BRK-B`) |
| `company_name` | text | Company name from the S&P universe list |
| `index_name` | text | `SP500`, `SP400`, or `SP600` |
| `cik` | integer | SEC Central Index Key |
| `tag` | text | Raw XBRL tag, e.g. `NetIncomeLoss` |
| `metric` | text | Human-readable tag label (`tlabel` from the taxonomy) |
| `value_date` | date | Period end date the value refers to |
| `filed_date` | date | Date the filing carrying this value hit EDGAR |
| `qtrs` | integer | Period length in quarters (see [qtrs convention](#the-qtrs-convention)) |
| `uom` | text | Unit of measure, usually `USD`; per-share tags use `USD/share` |
| `value` | numeric | The reported value, in raw units (dollars, not $B) |
| `adsh` | text | Accession number of the source filing |

**Indexes**: `ticker`, `value_date`, `tag`, `cik` (all btree).

```sql
-- Microsoft's 20 most recent reported facts
SELECT metric, value_date, qtrs, value
FROM sec_gold.tradable_financials
WHERE ticker = 'MSFT'
ORDER BY value_date DESC
LIMIT 20;
```

### `tradable_financials_pit`

Identical columns and indexes to `tradable_financials`, but holds the **as-first-reported** value for each fact (`rank_pit = 1`). This is the view to join against in any backtest: for a given `filed_date`, every row was genuinely knowable on that date, with no restatement look-ahead.

```sql
-- What did NVDA report for FY-end 2023-01-29, as originally filed?
SELECT metric, value_date, filed_date, value
FROM sec_gold.tradable_financials_pit
WHERE ticker = 'NVDA' AND value_date = '2023-01-29' AND qtrs = 4;
```

### `peer_stats`

Pre-computed cross-sectional z-scores: one row per **(ticker, canonical concept, fiscal year)**, scored against all S&P 1500 peers in the same **GICS sub-industry** and fiscal year. Covers fiscal years 2006–2026, 1,355 tickers, 101 sub-industries. Sourced from `tradable_financials` (latest-restated values, generic tag rules only).

Fiscal year is bucketed by `EXTRACT(YEAR FROM value_date)`, so NVDA's Jan-2025 FYE lands in `fiscal_year = 2025` alongside Apple's Sep-2025. Peer groups with fewer than 5 reporting companies are dropped (their z-scores would be noise).

| Column | Type | Description |
|---|---|---|
| `ticker` | text | Exchange ticker |
| `gics_sector` | text | GICS sector (11 values) |
| `gics_sub_industry` | text | GICS sub-industry — the peer-group key |
| `concept` | text | Canonical concept (FK to `canonical_concepts`) |
| `fact_type` | text | `flow` or `balance` (derived concepts excluded) |
| `fiscal_year` | integer | Calendar year of `value_date` |
| `value_date` | date | Actual period end date behind the bucketed year |
| `value` | numeric | Resolved value (sign-adjusted, best-priority tag) |
| `peer_count` | bigint | Companies in the (concept, year, sub-industry) group |
| `peer_mean` | numeric | Group mean |
| `peer_stddev` | numeric | Group sample standard deviation |
| `peer_min` / `peer_max` | numeric | Group extremes |
| `zscore` | numeric(12,4) | `(value − peer_mean) / peer_stddev`; NULL if stddev is 0 |

**Indexes**: `ticker`; `(concept, fiscal_year)`; `(gics_sub_industry, fiscal_year, concept)`.

```sql
-- NVDA revenue vs. semiconductor peers (z=4.2 in FY2025, 31 peers)
SELECT fiscal_year, value, zscore, peer_count
FROM sec_gold.peer_stats
WHERE ticker = 'NVDA' AND concept = 'revenue'
ORDER BY fiscal_year DESC;

-- Cheapest-by-nothing screen: most extreme net-income outliers, FY2025
SELECT ticker, gics_sub_industry, zscore
FROM sec_gold.peer_stats
WHERE concept = 'net_income' AND fiscal_year = 2025
ORDER BY zscore DESC
LIMIT 20;
```

---

## Tables

### `canonical_concepts`

The research taxonomy: 12 concepts that mean the same thing across companies regardless of which XBRL tag each company files. `fact_type` drives the `qtrs` branching in `latest_annual()` (`flow` → `qtrs = 4`, `balance` → `qtrs = 0`; `derived` concepts have no tags and are computed client-side).

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
| `total_debt` | Total Debt | balance | USD | Best-effort total interest-bearing debt from the dominant XBRL tag |
| `operating_cash_flow` | Cash from Operations | flow | USD | Net cash provided by operating activities |
| `capex` | Capital Expenditures | flow | USD | Payments to acquire property, plant and equipment |
| `free_cash_flow` | Free Cash Flow | derived | USD | Operating cash flow minus capex (computed client-side) |

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
| `revenue` | 1 | 60 | `Revenues` | Some banks file plain Revenues |
| `revenue` | 2 | 60 | `RevenuesNetOfInterestExpense` | Large-bank headline revenue |
| `revenue` | 3 | 60 | `InterestAndDividendIncomeOperating` | Fallback: gross interest income |
| `gross_profit` | 1 | any | `GrossProfit` | Companies that file a gross-profit line |
| `operating_income` | 1 | any | `OperatingIncomeLoss` | Near-universal for non-financials |
| `net_income` | 1 | any | `NetIncomeLoss` | Incl. noncontrolling interest |
| `net_income` | 2 | any | `NetIncomeLossAvailableToCommonStockholdersBasic` | "Available to common" filers |
| `eps_diluted` | 1 | any | `EarningsPerShareDiluted` | Near-universal (1,449 companies at FY2024) |
| `cash` | 1 | any | `CashAndCashEquivalentsAtCarryingValue` | Standard non-bank cash line |
| `cash` | 2 | any | `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` | ASC 230 total incl. restricted |
| `cash` | 3 | any | `Cash` | Legacy tag, small population |
| `cash` | 1 | 60 | `CashAndDueFromBanks` | Primary bank cash line |
| `cash` | 2 | 60 | `CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents` | Bank fallback |
| `total_assets` | 1 | any | `Assets` | Near-universal (1,488 companies) |
| `total_equity` | 1 | any | `StockholdersEquity` | Most common equity tag (1,419 companies) |
| `total_equity` | 2 | any | `StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest` | Consolidated groups w/ minority interest |
| `total_debt` | 1 | any | `DebtLongtermAndShorttermCombinedAmount` | Cleanest roll-up, only ~17 filers |
| `total_debt` | 2 | any | `LongTermDebt` | Older single-tag usage |
| `total_debt` | 3 | any | `LongTermDebtNoncurrent` | Most common but excludes current portion |
| `capex` | 1 | any | `PaymentsToAcquirePropertyPlantAndEquipment` | Most common capex tag (~1,008 companies) |
| `capex` | 2 | any | `PaymentsToAcquireProductiveAssets` | Industrials/utilities fallback (~210) |

Add coverage for a new tag with a plain `INSERT` — no function changes needed.

**Known gaps** (tracked in `features.md`): `total_debt` understates companies whose priority-3 tag omits short-term borrowings; a few hundred issuers (notably NVDA capex) use custom extension tags not mapped here; some banks (USB, TFC) file only decomposed revenue components and resolve to no revenue at all.

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
    p_mode       TEXT    DEFAULT 'latest'   -- 'latest' | 'pit'
) RETURNS NUMERIC
```

Resolves one concept to one value for an exact `(cik, value_date, qtrs)` by walking `concept_tag_map` (industry-specific rules first, then priority). Returns NULL if no mapped tag has a value there. Because it requires the exact period-end date, prefer `latest_annual()` unless you already know the company's fiscal calendar.

```sql
SELECT sec_gold.get_canonical(320193, 'revenue', '2025-09-30');  -- AAPL FY2025
```

### `get_canonical_by_ticker()`

Same signature and behavior with a `p_ticker TEXT` first argument, resolved through `sec_silver.ticker_map`.

```sql
SELECT sec_gold.get_canonical_by_ticker('AAPL', 'revenue', '2025-09-30');
```

### `latest_annual()`

```sql
sec_gold.latest_annual(
    p_cik     INTEGER,
    p_concept TEXT,
    p_mode    TEXT DEFAULT 'latest'
) RETURNS TABLE (value_date DATE, filed_date DATE, value NUMERIC, tag TEXT)
```

The fiscal-year-aware lookup: returns the **most recent** observation for a concept regardless of when the company's fiscal year ends. Branches on the concept's `fact_type`:

- `flow` concepts → most recent `qtrs = 4` (annual total, i.e. the latest 10-K figure).
- `balance` concepts → most recent `qtrs = 0` (point-in-time snapshot — note this is the latest **quarterly** balance sheet, which may be newer than the last 10-K).

Returns the winning tag so you can audit which mapping rule fired.

```sql
-- JPM FY2025 net income — a 2026q1-filed 10-K figure
SELECT * FROM sec_gold.latest_annual(19617, 'net_income');
--  value_date | filed_date  |    value    | tag
--  2025-12-31 | 2026-02-13  | 57000000000 | NetIncomeLoss  (≈ $57.0B)
```

### `latest_annual_by_ticker()`

Ticker wrapper for `latest_annual()`, same return shape.

```sql
SELECT * FROM sec_gold.latest_annual_by_ticker('NKE', 'revenue');  -- May FYE handled
```

### `company_snapshot()`

```sql
sec_gold.company_snapshot(
    p_ticker TEXT,
    p_mode   TEXT DEFAULT 'latest'
) RETURNS TABLE (concept TEXT, display_name TEXT, fact_type TEXT,
                 value_date DATE, value NUMERIC, tag TEXT)
```

One row per non-derived canonical concept (11 rows), each resolved via `latest_annual_by_ticker()`. The one-call company overview. Flows land on the last fiscal-year end; balances land on the most recent quarterly balance-sheet date, so the two groups can carry different `value_date`s — that is expected.

```sql
SELECT * FROM sec_gold.company_snapshot('AAPL');
--  concept             | value_date | value    | tag
--  revenue             | 2025-09-30 | $416.2B  | RevenueFromContractWithCustomer…
--  net_income          | 2025-09-30 | $112.0B  | NetIncomeLoss
--  total_assets        | 2025-12-31 | $379.3B  | Assets           ← newer 10-Q date
--  eps_diluted         | 2025-09-30 | 7.46     | EarningsPerShareDiluted (per-share)
--  ... (11 rows; free_cash_flow excluded — compute as operating_cash_flow − capex)
```

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

```sql
SELECT * FROM sec_gold.get_financials_by_ticker('AAPL');
```

---

## Caveats and data quirks

- **Stray `value_date`s.** The matviews span 1980-07-31 → 2031-12-31. Old dates are prior-period comparatives re-filed in modern filings; future dates are filer typos that SEC publishes as-is. Bound `value_date` in analyses that aggregate by date.
- **Universe is current-constituents-only.** `universe_sp1500` is today's S&P 1500 membership scraped from Wikipedia — historical analyses over the matviews carry **survivorship bias** (companies delisted or dropped from the index before today are absent).
- **Per-share vs. dollar units.** `eps_diluted` is `USD/share`; don't scale it by 1e9 alongside the dollar concepts. Check `uom` when working with raw tags.
- **`total_debt` is best-effort.** Priority-3 `LongTermDebtNoncurrent` (the most common resolution) excludes the current portion and short-term borrowings — treat cross-company debt comparisons accordingly.
- **Z-scores are raw-value scores.** `peer_stats` scores raw dollar values, so it mixes company size with performance; a z of +4 on revenue mostly means "much bigger than peers," not "growing faster." `peer_percentile` is robust to that skew. Both degrade in thin groups, which is why `peer_level = 'sector'` is the sounder default.
- **Concept coverage is not complete.** About 100 of 1,569 companies resolve to no revenue value in a given year because their XBRL tag is unmapped. Regulated utilities are the clearest cluster: 11 companies including NextEra report `RegulatedAndUnregulatedOperatingRevenue`, which is absent from `concept_tag_map`.
- **Ticker collisions.** `ticker_map` keeps the first CIK seen per ticker; a handful of ambiguous tickers may resolve to an unexpected issuer.

## Rebuilding and refreshing

```bash
uv run dera build-gold                 # full DDL rebuild (drops + recreates sec_gold)
uv run dera build-gold --refresh-only  # just REFRESH the two tradable matviews
```

Notes:

- `build-silver` **drops gold's matviews** via `DROP SCHEMA sec_silver CASCADE`, so a full gold rebuild (not `--refresh-only`) is required after every silver rebuild.
- `build-silver` now runs `ANALYZE` on `sec_silver.num_silver` and `sub_silver` at the end of the build. Previously this was documented as a manual step and lived in no code path; skipping it made the gold matview joins plan against a statistics-less 181M-row table (observed: 9 hours instead of ~1 minute).
- `--refresh-only` refreshes all four matviews in dependency order, `peer_stats` last. `fact_asof` was previously missing from that list, which left the availability-correct table stale behind every `as_of_*` function.

## Derived concepts

`canonical_concepts.fact_type` has always permitted `'derived'` and `'ratio'`.
Until now nothing computed either: `free_cash_flow` was declared with no tags
and then explicitly excluded from every consumer, so the enum was pure
forward-declaration.

`sec_gold.concept_formula` makes it real. A derived concept is a linear
combination of other concepts:

| Concept | Formula | Why |
|---|---|---|
| `gross_profit` | `revenue - cost_of_revenue` | Recovers 253 issuers that file cost but no gross profit line |
| `free_cash_flow` | `operating_cash_flow - capex` | Was declared and uncomputed for months |
| `total_debt` | `debt_noncurrent + debt_current` | Fires only when no combined debt tag resolves |

Two rules make this safe.

**One level deep.** Operands must resolve from tags, never from another
formula. This is enforced by construction rather than convention: the formula
branch calls `resolve_direct()`, which knows nothing about formulas, so
recursion is impossible. The cost is writing `revenue - cost_of_revenue`
instead of chaining; the benefit is no cycles and no ordering questions.

**`required` says what a missing operand means.** When true, the result is
NULL without it, because gross profit from revenue alone is not gross profit.
When false, the operand is treated as zero, because a company reporting no
capex still has a free cash flow. At least one operand must resolve either
way, so a company with no debt at all yields NULL rather than a confident zero.

Direct tags always win. An issuer that files `GrossProfit` outright is never
handed a reconstruction.

### The total_debt fix

`LongTermDebtNoncurrent` used to sit at priority 3 on `total_debt` itself. It
resolves for most issuers and **excludes the current portion**, so `total_debt`
was not merely sparse at 53% coverage, it was silently understated wherever it
did resolve. A leverage ratio built on it was wrong, which is worse than
missing. That tag now lives on `debt_noncurrent`, and `total_debt` falls
through to the sum of the two components.

Deliberately not mapped: `RepaymentsOfLongTermDebt` and
`ProceedsFromIssuanceOfLongTermDebt`. Both rank high in any tag-frequency scan
and both are cash-flow movements, not balances.

### Coverage ceilings are sometimes structural

`gross_profit` reaches 857 of 1,569 companies, not 90%. Banks, REITs and
insurers do not report a gross profit line at all, so the remainder is not a
mapping failure and no amount of tag work will close it. Any screen using gross
margin should say so rather than quietly dropping half the book.

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
| `060_canonical_function.sql` | `resolve_direct()`, `get_canonical()`, `get_canonical_by_ticker()` |
| `065_asof_functions.sql` | the five `as_of_*` functions |
| `070_fiscal_year_views.sql` | `latest_annual()`, `latest_annual_by_ticker()`, `company_snapshot()` |
| `080_peer_stats.sql` | `peer_stats` (resolves derived concepts too) |

Files run in lexical order within the directory, so the numeric prefix is
load-bearing. `065_asof_functions.sql` sits after `050` because it resolves
canonical concepts and `concept_tag_map` does not exist before then.
