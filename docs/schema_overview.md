# Schema overview

Every table and materialized view in the database, what it is for, and which
layer it belongs to. **Sizes and row counts are as of 2026-09-04.**

If you are new here, read `docs/data_sources.md` first — it explains what is
flowing in. `docs/gold_tables.md` is the deep reference for `sec_gold`; this
document is the map.

---

## The four schemas

```
sec_raw          bronze    37 GB   raw SEC text, all TEXT, no constraints
   └─ sec_silver silver    62 GB   typed, deduplicated, bitemporal facts
        └─ sec_gold  gold  40 GB   query-facing views, concepts, peer stats
   sec_reference  spine   269 MB   companies, securities, universes, calendar
```

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
| `num_raw` | 176.2M | 30 GB | Numeric facts — the actual financial data |
| `pre_raw` | 44.1M | 6.7 GB | Presentation: how facts map to statement lines |
| `tag_raw` | 4.7M | 1.2 GB | XBRL taxonomy: tag names, labels, definitions |
| `sub_raw` | 419.8K | 141 MB | Submissions: one row per filing |
| `load_log` | 70 | 32 kB | Which quarters have been loaded (drives incremental load; a logged quarter is refused a second time) |

## `sec_silver` — silver

Typed, deduplicated and **bitemporal**. This is where point-in-time correctness
is established.

| Table | Rows | Size | What it is |
|---|---:|---:|---|
| `num_silver` | 185.0M | 60 GB | **The core fact table.** Every vintage of every fact |
| `tag_silver` | 4.5M | 1.5 GB | Deduplicated taxonomy |
| `sub_silver` | 433.7K | 111 MB | Filings with `known_at` (acceptance instant) and `tradable_from` |
| `ticker_map` | 10.2K | 1.3 MB | Legacy CIK ↔ ticker crosswalk (superseded by `sec_reference`) |
| `universe_sp1500` | 1,505 | 376 kB | **Today's** S&P 1500 membership — no dates; the source of the S&P 400/600 snapshot intervals in `sec_reference.index_membership` |

`num_silver` carries the availability columns everything else depends on:
`known_at`, `tradable_from`, `vintage_seq`, `superseded_known_at`,
`superseded_tradable`, `is_original_disclosure`. An as-of query is a half-open
interval scan returning exactly one row per fact, with no window function at
query time. (It no longer carries indexes on `rank_pit` and `rank_latest`: 2.4 GB
that the planner never used, since `= 1` matches most of the table.)

> **Caveat — `universe_sp1500` is current-constituents-only.** It has no date
> columns at all. Nothing in gold joins to it directly any more: gold reads
> `sec_reference.index_membership`, which holds replayed S&P 500 history and,
> for the S&P 400 and 600 only, this table's snapshot as a labelled interval
> from 1900-01-01 until their histories are replayed.

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
| `index_observation` | 107,555 | Raw S&P 500 constituent sightings: 214 monthly Wikipedia captures, 2008-09 to 2026-08, GICS as the page gave it |
| `index_capture` | 214 | One row per capture with its size and partial flag (none partial) |
| `index_observation_resolved` | 107,555 | The same sightings with a CIK from the page (74,743), by continuity (28,851) or by name (3,373); 588 unresolved |
| `index_membership_unresolved` | 40 | Tickers that never resolved to a CIK — the members the historical universe is missing, listed rather than guessed |
| **`index_membership`** | **2,708** | **Dated membership with GICS as of the interval**: 1,738 replayed S&P 500 intervals over 840 companies (`wikipedia_history`), 970 S&P 400/600 snapshot intervals (`current_snapshot`) |
| `index_membership_latest` | 1,711 | One row per company: its current or most recent membership, the label gold falls back to |
| **`security`** | **17,030** | **A tradable instrument, distinct from its issuer.** Listed classes only |
| `listing` | 28,287 | Security ↔ ticker over time; `source` says observed crosswalk (21,844), extended crosswalk (6,352) or share-class map (91) |
| `eligibility` | 18,559 | Universe membership intervals (`filers_10k_15m` 17,695, `sp500` 864), with reasons in and out |
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

A second universe, `sp500`, is derived from `index_membership` for every listed
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
| `fact_asof` | matview | 97.9M | 33 GB | **Bitemporal facts, every vintage. The backtest source** |
| `tradable_financials` | matview | 12.4M | 3.5 GB | Latest-restated facts, one row per fact; index membership and GICS dated |
| `tradable_financials_pit` | matview | 12.4M | 3.6 GB | Earliest-sighting twin |
| `peer_stats` | matview | 479.6K | 118 MB | Cross-sectional scores at sector and sub-industry; each fiscal year's panel is the index of the time |
| `share_class_shares` | matview | 777.5K | 218 MB | Per-class share counts for 9,654 companies, delisted included — the market-cap denominator |
| `canonical_concepts` | table | 15 | — | Research taxonomy (revenue, total_debt, …) |
| `concept_tag_map` | table | 38 | — | Priority-ordered XBRL tag resolution |
| `concept_formula` | table | 6 | — | Derived concepts as linear combinations |
| `metric_aliases` | table | 4 | — | Legacy display-name remap |

Plus roughly twenty functions — `get_canonical()`, `latest_annual()`,
`company_snapshot()`, the `as_of_*` accessors (with `as_of_snapshot` keyed by
CIK or by ticker), `shares_outstanding_at()`, `share_classes_at()`. All
documented in `docs/gold_tables.md`.

---

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
uv run dera verify     # 50 checks; exits non-zero on any FAIL
uv run pytest          # unit tests for the pure Python
```

Covers restatement preservation, availability correctness, crosswalk capture
quality, share-class summing, derived-concept resolution, and the survivorship /
future-existence tests on the universe. Checks 29–50 each name the defect found
in the 2026-09-04 review, or the gap closed since, that they guard against.
