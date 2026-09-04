# Schema overview

Every table and materialized view in the database, what it is for, and which
layer it belongs to. Sizes and row counts are from 2026-09-04.

If you are new here, read `docs/data_sources.md` first — it explains what is
flowing in. `docs/gold_tables.md` is the deep reference for `sec_gold`; this
document is the map.

---

## The four schemas

```
sec_raw          bronze    37 GB   raw SEC text, all TEXT, no constraints
   └─ sec_silver silver    64 GB   typed, deduplicated, bitemporal facts
        └─ sec_gold  gold  40 GB   query-facing views, concepts, peer stats
   sec_reference  spine   166 MB   companies, securities, universes, calendar
```

`sec_reference` deliberately sits **outside** the bronze→silver→gold chain.
`build-silver` opens with `DROP SCHEMA sec_silver CASCADE`, and the trading
calendar, company spine and security model must survive that — `sub_silver`
resolves `tradable_from` against the calendar during its own build.

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
| `load_log` | 68 | 32 kB | Which quarters have been loaded (drives incremental load) |

## `sec_silver` — silver

Typed, deduplicated and **bitemporal**. This is where point-in-time correctness
is established.

| Table | Rows | Size | What it is |
|---|---:|---:|---|
| `num_silver` | 185.0M | 62 GB | **The core fact table.** Every vintage of every fact |
| `tag_silver` | 4.5M | 1.5 GB | Deduplicated taxonomy |
| `sub_silver` | 433.7K | 111 MB | Filings with `accepted_time` and `tradable_from` |
| `ticker_map` | 10.2K | 1.3 MB | Legacy CIK ↔ ticker crosswalk (superseded by `sec_reference`) |
| `universe_sp1500` | 1,505 | 376 kB | **Today's** S&P 1500 membership — no dates, see caveat below |

`num_silver` carries the availability columns everything else depends on:
`known_at`, `tradable_from`, `vintage_seq`, `superseded_known_at`,
`superseded_tradable`, `is_original_disclosure`. An as-of query is a half-open
interval scan returning exactly one row per fact, with no window function at
query time.

> **Caveat — `universe_sp1500` is current-constituents-only.** It has no date
> columns at all, so anything joining to it inherits survivorship bias. The
> replacement is `sec_reference.universe_at()`; the gold matviews have not been
> rewired to it yet.

## `sec_reference` — the spine

Companies, securities, identifiers and universes. Survivorship-free by
construction: it holds every CIK that ever filed, not the ones that survived.

| Table | Rows | What it is |
|---|---:|---|
| `company` | 17,015 | Every CIK that ever filed. The survivorship-free population |
| `company_name` | 31,090 | Historical names with validity intervals |
| `company_ticker` | 36,032 | Dated CIK ↔ ticker intervals with `is_primary` |
| `ticker_observation` | 154,431 | Raw dated crosswalk observations (Wayback replay) |
| **`security`** | **17,031** | **A tradable instrument, distinct from its issuer** |
| `listing` | 20,711 | Security ↔ exchange ↔ ticker over time |
| `eligibility` | 17,727 | Universe membership intervals, with reasons in and out |
| `delisting_event` | 4,553 | Delistings as investment events, not missing data |
| `corporate_action` | 0 | Declared, unpopulated |
| `share_class` | 27 | Hand-mapped share class → ticker allowlist (9 CIKs) |
| `trading_calendar` | 4,947 | NYSE sessions, for availability arithmetic |
| `security_event_raw` | 910,661 | Staging: raw EDGAR lifecycle events |
| `company_name_raw` | 31,093 | Staging: raw name history |

### The company/security distinction

This is the part most worth understanding. `company_ticker` maps a CIK to a
ticker with no notion of an instrument that begins and ends. `security` is the
tradable thing, and it carries the two dates that make a historical universe
possible:

- `first_trade_date` + `first_trade_basis` — when it became tradable, and on what
  evidence. The basis matters: `8-A` is a listing registration, `424B` a pricing,
  `already_reporting` a conservative upper bound for companies public before
  EDGAR existed, `first_edgar_filing` only a floor on company existence. Measured
  distribution: 44.5% / 2.5% / 52.5% / 0.5%.
- `delisting_date` — when it stopped being tradable, derived from Form 25 by a
  behavioural rule, not by the presence of the form. Colgate-Palmolive has filed
  five Form 25s and JPMorgan forty-six; neither has ever delisted.

Two invariants are enforced by CHECK constraint, not convention: no eligibility
interval may begin before `first_trade_date` (blocks future-existence bias) or
outlive `delisting_date` (blocks survivorship bias).

## `sec_gold` — gold

Query-facing. Rebuild with `dera build-gold`; see `docs/gold_tables.md` for the
full reference including every function signature.

| Object | Kind | Rows | Size | What it is |
|---|---|---:|---:|---|
| `fact_asof` | matview | 97.9M | 33 GB | **Bitemporal facts, every vintage. The backtest source** |
| `tradable_financials` | matview | 11.8M | 3.4 GB | Latest-restated facts, one row per fact |
| `tradable_financials_pit` | matview | 11.8M | 3.5 GB | As-first-reported twin |
| `peer_stats` | matview | 530.3K | 126 MB | Cross-sectional scores at sector and sub-industry |
| `share_class_shares` | matview | 504.8K | 138 MB | Per-class share counts, the market-cap denominator |
| `canonical_concepts` | table | 15 | — | Research taxonomy (revenue, total_debt, …) |
| `concept_tag_map` | table | ~45 | — | Priority-ordered XBRL tag resolution |
| `concept_formula` | table | 6 | — | Derived concepts as linear combinations |
| `metric_aliases` | table | 4 | — | Legacy display-name remap |

Plus roughly twenty functions — `get_canonical()`, `latest_annual()`,
`company_snapshot()`, the five `as_of_*` accessors, `shares_outstanding_at()`,
`share_classes_at()`. All documented in `docs/gold_tables.md`.

---

## Which table should I read?

| I want to… | Read | Not |
|---|---|---|
| Backtest — what was knowable on date T | `fact_asof` + `as_of_*()` | `tradable_financials` |
| Know who was investable on date T | `sec_reference.universe_at()` | `universe_sp1500` |
| Analyse historical results as now understood | `tradable_financials` | the `_pit` twin |
| Screen cross-sectionally today | `peer_stats` | — |
| Resolve one metric across companies | `get_canonical()` | raw XBRL tags |
| Know when a security began or stopped trading | `sec_reference.security` | `company_ticker` |

Two rules worth internalising. **`peer_stats` is not availability-correct** — it
is built from restated values with moments computed over the finished panel, so
it knows the future; it is for dashboards and screens, never backtests. And the
`as_of_*` functions **have no default knowledge date**, deliberately: omitting it
is a call-site error rather than a silent look-ahead.

## Verifying

```bash
uv run dera verify     # 28 checks; exits non-zero on any FAIL
```

Covers restatement preservation, availability correctness, crosswalk fan-out,
share-class summing, and the survivorship / future-existence tests on the
universe.
