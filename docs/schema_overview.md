# Schema overview

Every table and materialized view in the database, what it is for, and which
layer it belongs to. **Sizes and row counts are as of 2026-10-14.**

If you are new here, read `docs/data_sources.md` first — it explains what is
flowing in. `docs/gold_tables.md` is the deep reference for `sec_gold`; this
document is the map.

---

## The five schemas

```
sec_raw          bronze    41 GB   raw SEC text, all TEXT, no constraints
   └─ sec_silver silver    80 GB   typed, deduplicated, bitemporal facts
        └─ sec_gold  gold  43 GB   query-facing views, concepts, peer stats
   sec_reference  spine   412 MB   companies, securities, universes, calendar
   sec_market     prices   185 MB   month-end closes (Yahoo), the factor panel, the backtest
```

164 GB in all (2026-10-14). 6.5 GB of it is free space inside
`sec_silver.num_silver` — 11.6% of that heap, measured with the optional
`pgstattuple` extension's `pgstattuple_approx` — left by the quarterly folds:
a fold deletes the replaced quarter and inserts the new one, and Postgres keeps
the freed pages for the next load rather than returning them to the file
system. The other large heaps are 1–3% free; nothing needs a `VACUUM FULL`.

`sec_reference` deliberately sits **outside** the bronze→silver→gold chain.
`build-silver` opens with `DROP SCHEMA sec_silver CASCADE`, and the trading
calendar, company spine and security model must survive that — `sub_silver`
resolves `tradable_from` against the calendar during its own build. When the
filing index is absent, `build-silver` also leaves the security model's DDL
untouched rather than dropping tables it cannot refill.

---

## `sec_raw` — bronze

Raw SEC DERA text, loaded by `dera_pipeline.loader` via `COPY FROM STDIN`.
Everything is `TEXT` with no constraints: the goal is to land the file exactly as
SEC published it, so any type failure surfaces in silver where it can be
reasoned about rather than at ingest.

| Table | Rows | Size | What it is |
|---|---:|---:|---|
| `num_raw` | 188.9M | 32 GB | Numeric facts — the actual financial data |
| `pre_raw` | 46.5M | 7.1 GB | Presentation: how facts map to statement lines |
| `tag_raw` | 5.0M | 1.3 GB | XBRL taxonomy: tag names, labels, definitions |
| `sub_raw` | 440.2K | 149 MB | Submissions: one row per filing |
| `load_log` | 71 | 64 kB | Which quarters have been loaded (drives incremental load; a logged quarter is refused unless `--force` replaces it) |

Every row of the four raw tables carries `source_quarter`, the DERA file it came from, filled by a transaction-local setting the loader makes before each COPY. It is what `dera load --quarter Q --force` deletes by and what `dera build-silver --quarter Q` reads; a BRIN index on it is enough because rows are appended a quarter at a time.

## `sec_silver` — silver

Typed, deduplicated and **bitemporal**. This is where point-in-time correctness
is established.

| Table | Rows | Size | What it is |
|---|---:|---:|---|
| `num_silver` | 188.9M | 69 GB | **The core fact table.** Every vintage of every fact |
| `tag_silver` | 4.5M | 1.4 GB | Deduplicated taxonomy |
| `sub_silver` | 440.2K | 121 MB | Filings with `known_at` (acceptance instant) and `tradable_from` |
| `pre_silver` | 46.5M | 9.6 GB | Every statement line of every filing as rendered: statement, row order, the tag behind the line and the label the filer printed. The balance-sheet face `sec_gold.debt_face` reads |
| `ticker_map` | 10.2K | 1.3 MB | Legacy CIK ↔ ticker crosswalk (superseded by `sec_reference`) |
| `universe_sp1500` | 1,505 | 336 kB | **Today's** S&P 1500 membership — no dates; only the `is_primary` tie-break reads it now |

`num_silver` carries the availability columns everything else depends on:
`known_at`, `tradable_from`, `vintage_seq`, `superseded_known_at`,
`superseded_tradable`, `is_original_disclosure`. An as-of query is a half-open
interval scan returning exactly one row per fact, with no window function at
query time. (It no longer carries indexes on `rank_pit` and `rank_latest`: 2.4 GB
that the planner never used, since `= 1` matches most of the table.)

> **Caveat — `universe_sp1500` is current-constituents-only.** It has no date
> columns at all. Nothing in gold joins to it any more: gold reads
> `sec_reference.index_membership`, replayed history for all three indexes.

### Raw SEC fields → silver columns

Silver renames and drops enough that a reader consulting
[`SEC_Financial_Dataset_Field_Definitions.md`](SEC_Financial_Dataset_Field_Definitions.md)
will not find several fields under the names SEC uses.

| SEC raw | Silver | Note |
|---|---|---|
| `sub.period` | `sub_silver.period_date` | renamed |
| `sub.accepted` | `sub_silver.known_at` | renamed; this is the acceptance instant |
| `sub.filed` | `sub_silver.filed_date` | renamed |
| `sub.prevrpt` | `sub_silver.was_amended_later` | renamed |
| `sub.detail` | `sub_silver.is_detailed` | renamed |
| — | `sub_silver.tradable_from` | **derived** from `known_at` against the NYSE calendar |
| `num.ddate` | `num_silver.value_date` | renamed |
| — | `num_silver.{known_at, tradable_from, vintage_seq, superseded_known_at, superseded_tradable, is_original_disclosure, rank_pit, rank_latest}` | **derived** — the bitemporal machinery |
| — | `num_silver.{cik, form, filed_date, tlabel}` | joined in from `sub_silver` / `tag_silver` |

21 `sub` columns are dropped entirely (mailing address, EIN, former name,
filer-status flags and similar), as is nothing from `num`.

## `sec_reference` — the spine

Companies, securities, identifiers and universes. Survivorship-free by
construction: it holds every CIK that ever filed, not the ones that survived.

| Table | Rows | What it is |
|---|---:|---|
| `company` | 17,015 | Every CIK that ever filed. The survivorship-free population |
| `company_name` | 31,090 | Historical names with validity intervals |
| `ticker_observation` | 861,755 | Raw dated crosswalk observations: 81 captures, monthly from 2018-12 |
| `ticker_capture` | 81 | One row per capture with its size and whether it is partial |
| `company_ticker` | 41,925 | Dated CIK ↔ ticker intervals with `is_primary` and `source`: 35,520 observed intervals over 20,326 CIKs (12,321 absent from SEC's live file) plus 6,405 back-extended single-ticker histories reaching the first filing |
| `cik_succession` | 223 | Ticker handoffs between two registrants in SEC's own file (the old CIK's primary interval ends where a newer CIK's begins; the newer CIK filed later, or has not filed in DERA yet while the old one was filing up to the handoff, as ExxonMobil Holdings 2115436 from 2026-07): evidence of a holding-company reorganisation, consumed only by the membership split |
| `index_observation` | 233,265 | Raw constituent sightings from monthly Wikipedia captures: S&P 500 214 (2008-09 →), S&P 400 153 (2011-01 →), S&P 600 92 (2018-08 →); GICS as the page gave it |
| `index_sighting` | 224,536 | The sightings after the S&P 1000 rule: rows of an oversized early S&P 600 capture that the same month's S&P 400 page also lists are removed |
| `index_capture` | 459 | One row per capture with its size and partial flag (16 partial: the S&P 600 captures that are not a list of about 600) |
| `index_observation_resolved` | 214,443 | The same sightings with a CIK per run: from the page (150,851), the dated crosswalk (59,101), a name the company bore at the time (4,043), the allowlist (125) or the neighbouring run across partial captures (81); 242 unresolved |
| `index_cik_override` | 8 | Hand-resolved constituent runs, (index, ticker, first sighting) → CIK, each row citing its evidence (`data/reference/index_cik_overrides.csv`); applied only where the page, the crosswalk and the name failed, and check 61 fails a redundant row |
| `index_membership_unresolved` | 36 | Tickers no rule resolved to a CIK, listed rather than guessed (S&P 500 25, S&P 400 8, S&P 600 3): companies that never filed XBRL, page errors and ghost rows; none has facts in DERA |
| **`index_membership`** | **6,342** | **Dated membership with GICS as of the interval, all three indexes replayed**: S&P 500 1,864 intervals over 841 companies, S&P 400 2,155 over 1,046, S&P 600 2,323 over 1,160; 61 intervals re-keyed to a predecessor registrant by `cik_succession` (34 cut at the handoff, 27 at the successor's first EDGAR filing); no interval starts before its registrant's first filing by the page's "date added"; no snapshot rows remain |
| `index_membership_latest` | 2,417 | One row per company: its current or most recent membership, the label gold falls back to |
| `index_membership_timeline` | 6,352 | `index_membership` resolved to one non-overlapping interval set per company (2,417 companies; the later start wins). What gold joins with a plain range condition; an EXCLUDE constraint enforces the non-overlap |
| **`security`** | **17,030** | **A tradable instrument, distinct from its issuer.** Listed classes only |
| `listing` | 28,287 | Security ↔ ticker over time; `source` says observed crosswalk (21,844), extended crosswalk (6,352) or share-class map (91) |
| `eligibility` | 36,199 | Universe membership intervals with reasons in and out: `filers_10k_15m` 17,700, `filers_10k_15m_strict` 17,635 (1,832 of them entering at a 424B pricing rather than a first periodic report), `sp500` 864 |
| `delisting_event` | 7,119 | Outcomes: 4,498 exchange notices (Form 25), 2,621 deregistrations (Form 15) |
| `corporate_action` | 0 | Declared, unpopulated |
| `share_class` | 99 | Share class → ticker allowlist (66 CIKs): 27 hand-mapped rows plus 72 derived from 10-K cover pages, every row citing its filing |
| `company_label` | *(view)* | Best-known display name per CIK — joined by both `tradable_financials` matviews |
| `trading_calendar` | 4,947 | NYSE sessions to 2028-09-01, for availability arithmetic |
| `security_event_raw` | 905,049 | Staging: raw EDGAR lifecycle events |
| `company_name_raw` | 31,093 | Staging: raw name history |

Rebuild the security model with `dera build-security-model` (it needs
`dera fetch-filing-index` to have run first). After a reference refresh, use
`dera rebuild-reference`, which reloads the CSVs, refills the spine in place,
rebuilds the security model and refreshes the gold matviews whose inputs
changed. There is no shell helper — an
earlier shell helper under tools/ loaded an 18-CIK slice and would silently
truncate the model to 18 securities, so it was deleted in favour of the CLI.

### The company/security distinction

This is the part most worth understanding. `company_ticker` maps a CIK to a
ticker with no notion of an instrument that begins and ends. `security` is the
tradable thing, and it carries the dates that make a historical universe
possible:

- `first_trade_date` + `first_trade_basis` — when it became tradable, and on what
  evidence. The basis matters: `8-A` is a listing registration, `424B` a pricing,
  `already_reporting` the first periodic report, `first_edgar_filing` only a floor
  on company existence. Measured distribution: 44.5% / 2.5% / 52.5% / 0.5%.
  `already_reporting` is late-but-true for a company public before EDGAR and
  **early** for one that reported before its equity traded; `first_pricing_date`
  (the earliest 424B pricing, populated for 7,981 securities) is kept as evidence
  for a stricter reading.
- `delisting_date` — when it stopped being tradable, derived from a Form 25 or,
  failing that, a Form 15, by a behavioural rule rather than by the presence of
  the form. Colgate-Palmolive has filed five Form 25s and JPMorgan forty-six;
  neither has ever delisted. `delisting_event.reason` records which evidence
  class ended it.

Two invariants are enforced by CHECK constraint, not convention: no eligibility
interval may begin before `first_trade_date` (blocks future-existence bias) or
outlive `delisting_date` (blocks survivorship bias).

`sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30')` returns 7,298
members, 3,012 of them (41%) since delisted or deregistered. 4,058 carry a
back-extended ticker flagged `ticker_is_asof = false`, and 1,476 have no ticker
label at all: they left before the first capture in 2018-12 and SEC's file never
carried them, or their ticker changed before then.

`filers_10k_15m_strict` is the same population with one change: a security whose
first trade is known only from its first periodic report enters at its first
424B pricing when one exists later. 7,082 members on 2015-06-30 against 7,298,
6,837 against 6,868 on 2024-06-30. The ones that leave are mostly OTC-quoted
micro-caps before a priced uplisting and non-traded REITs before their IPO
(Plymouth Industrial, priced 2017-06-09); the known cost is a pre-EDGAR listed
company whose later 424B was a follow-on (LGL Group would enter in 2017).

A third universe, `sp500`, is derived from `index_membership` for every listed
security of a member company, clipped to the security's lifecycle like the
first. `sec_reference.index_members('SP500', DATE '2015-06-30')` gives the
constituents on a date with their GICS as of that date; `universe_at('sp500',
…)` gives the securities. SVB Financial is a member from 2018-03-19 to
2023-03-24, Tesla from 2020-12-21, Twitter from 2018-06-07 to 2022-10-29.

## `sec_gold` — gold

Query-facing. Rebuild with `dera build-gold`; see `docs/gold_tables.md` for the
full reference including every function signature.

| Object | Kind | Rows | Size | What it is |
|---|---|---:|---:|---|
| `suspect_fact` | matview | 5.6K | 2.2 MB | The silver rows gold refuses, with the reason: a period ending after its filing date (5,546) or a balance-sheet column a thousand or a million times too small (87); anti-joined by the two fact matviews and the silver-reading functions |
| `fact_asof` | matview | 99.4M | 33 GB | **Bitemporal facts, every vintage. The backtest source** |
| `tradable_financials` | matview | 16.5M | 4.6 GB | Latest-restated facts, one row per fact; index membership and GICS dated |
| `tradable_financials_pit` | matview | 16.5M | 4.7 GB | Earliest-sighting twin |
| `debt_face` | matview | 406.8K | 138 MB | Every 10-K and 10-Q balance sheet read for borrowing lines by the labels the filer printed; `zero_by_face` (83,631 filings) is the only source of a `total_debt` of zero and `reason` says why every other face is not one |
| `peer_stats` | matview | 761.7K | 196 MB | Cross-sectional scores at sector and sub-industry; each fiscal year's panel is the index of the day for all three indexes; scored concepts only |
| `share_class_shares` | matview | 788.0K | 220 MB | Per-class share counts for 9,679 companies, delisted included — the market-cap denominator |
| `canonical_concepts` | table | 49 | — | Research taxonomy: 28 scored concepts (revenue, total_debt, net_margin, gross_profit_to_assets, ocf_to_assets, revenue_growth, …) and 21 unscored operands (19 instrument lines, the two cost components) |
| `concept_tag_map` | table | 112 | — | Priority-ordered XBRL tag resolution; dollar facts only |
| `concept_formula_variant` | table | 4 | — | The variants of a derived concept, in order, with an industry scope and a custom-line guard |
| `concept_formula` | table | 25 | — | Derived concepts as linear combinations, per variant |
| `concept_ratio` | table | 13 | — | Margins, returns, gross profit and operating cash flow to assets, leverage and year-over-year growth as ratios of concepts |
| `metric_aliases` | table | 4 | — | Legacy display-name remap |

Plus roughly twenty functions — `get_canonical()`, `latest_annual()`,
`company_snapshot()`, the `as_of_*` accessors (with `as_of_snapshot` keyed by
CIK or by ticker), `peer_stats_asof()` (the peer cross-section as it was
knowable on a date, computed on demand), `as_of_quarterly()` and
`as_of_trailing()` (every fiscal quarter of every flow concept with its
trailing twelve months and quarter-over-quarter, year-over-year and
trailing growth, as knowable on a date; `quarterly()` and `trailing()` as of
today; nothing stored), `as_of_surprise()` and `surprise_asof()` (standardized
unexpected earnings per company and ranked across an index, as knowable on a
date; nothing stored), `as_of_profitability()` and `profitability_asof()`
(quarterly return on equity and on assets over the prior quarter's balance,
per company and ranked across an index; nothing stored), `factor_sheet_asof()`
(the nine factors per constituent with index and sector percentiles and a
composite; nothing stored), `shares_outstanding_at()`,
`share_classes_at()`. All documented in `docs/gold_tables.md`.

---

## `sec_market` — prices, the factor panel and the backtest

Not SEC data: month-end prices from a vendor, and the two objects that turn
the factor sheet into a test of returns. Its own schema so that nothing in
`sec_gold` depends on it and a reader always knows which numbers came from a
filing and which from Yahoo. Loaded by `uv run dera load-prices` and
`uv run dera build-factor-panel`; DDL in `sql/07_market/`. As of 2026-10-12.

| Object | Kind | Rows | What it is |
|---|---|---|---|
| `monthly_price` | table | 303.8K | One row per company, primary ticker and month end, 2009-01 to the last complete month, for the 1,693 companies ever in the S&P 1500 whose primary ticker is still listed. `close_split_adj` is Yahoo's split-restated close, `adj_close` its total-return index, `close_raw` the as-traded close reconstructed from the split ratios (Apple July 2020: 106.26, 102.80, 425.04) |
| `price_load` | table | 1 per load | When the vendor was asked, how many symbols answered, how many members have no open listing |
| `monthly_return` | view | — | `ret_1m` per company and month from `adj_close`; NULL across a gap, when either month did not trade, or when the prior close was under a dollar |
| `factor_panel` | table | 500 / 400 / 600 per date, 1,500 for the union | `sec_gold.factor_sheet_asof` stored per (index, knowledge date, company) for SP500 (2010 on), SP400 (2011 on) and SP600 (2018 on, the replayed histories); `SP1500` is the union of the three on a date, one row per company, with the percentiles and composite recomputed over all of them by the sheet's rule (`build_factor_panel_union`, 2026-10-13); CHECKs refuse any row whose period or availability is after its own knowledge date |

Functions: `price_at(cik, asof)` (the newest month-end close strictly before
the date, within 45 days), `market_cap_at(cik, asof)` (that close times the
cover-page shares knowable on the date, from `sec_gold.shares_outstanding_at`),
`build_factor_panel(index, asof)` (one knowledge date of the panel; `SP1500` dispatches to `build_factor_panel_union(name, components[], asof)`, the re-rank of the stored component rows, which refuses a date any component lacks),
`backtest(index, factor, freq, from, to, buckets)` (sort the panel into equal
buckets on each rebalance date, monthly, quarterly or annual, hold
equal-weighted to the next, and return each bucket's monthly total return,
the equal-weight benchmark and the top-minus-bottom spread) and
`backtest_summary(...)` (per bucket and for the spread: months, mean monthly
return, t-statistic, annualised return, Sharpe ratio, hit rate).

**Survivorship.** Yahoo returns nothing for a delisted ticker and re-keys a
reused one to its current holder, so only open listings are loaded: 718 of the
2,417 companies ever in the S&P 1500 have no listed security today (acquired,
taken private, failed) and no prices here. Every bucket in a backtest holds
survivors only; the spread between buckets is less exposed than a bucket's
level, not immune. The paid source the roadmap names (Polygon flat files) is
what closes this. The equal-weight return of the priced companies tracks the
Fama-French market at a correlation of 0.93 over 2010-2026 (beta 1.14, the
equal-weight tilt), which is the sanity check that the series are the right
companies in the right units.

## Which table should I read?

| I want to… | Read | Not |
|---|---|---|
| Backtest — what was knowable on date T | `fact_asof` + `as_of_*()` | `tradable_financials` |
| Know who was investable on date T | `sec_reference.universe_at()` | `universe_sp1500` |
| Know who was in the S&P 500 on date T, with GICS then | `sec_reference.index_members()` | `universe_sp1500` |
| Analyse historical results as now understood | `tradable_financials` | the `_pit` twin |
| Screen cross-sectionally today | `peer_stats` | — |
| Resolve one metric across companies | `get_canonical()` | raw XBRL tags |
| Know when a security began or stopped trading | `sec_reference.security` | `company_ticker` |
| Count shares per class for a market cap | `share_class_shares` | `shares_outstanding_at()` alone |

Two rules worth internalising. **`peer_stats` is not availability-correct** — it
is built from restated values with moments computed over the finished panel, so
it knows the future; it is for dashboards and screens, never backtests. And the
`as_of_*` functions **have no default knowledge date**, deliberately: omitting it
is a call-site error rather than a silent look-ahead — and a ticker the
crosswalk cannot resolve on that date raises rather than returning empty rows.

## Verifying

```bash
uv run dera verify     # 75 checks; exits non-zero on any FAIL
uv run pytest          # unit tests for the pure Python
```

Covers restatement preservation, availability correctness, crosswalk capture
quality, share-class summing, derived-concept resolution, and the survivorship /
future-existence tests on the universe. Checks 29–60 each name the defect found
in the 2026-09-04 review, or the gap closed since, that they guard against.
