# Data sources and provenance

What this project downloads, where each dataset comes from, what it becomes, and
how far any given number can be traced back toward the document that reported it.

Read this before `docs/schema_overview.md` — the schemas make more sense once you
know what is flowing into them.

**Figures throughout this file are as of 2026-09-04.**

---

## The short version

Everything here is **free and public**. There is no vendor feed and no licensed
data. Five acquisition paths, in rough order of how much they matter:

| # | Source | Lands in | On disk | Refresh |
|---|---|---|---|---|
| 1 | SEC DERA Financial Statement Data Sets | `data/raw/<year>q<n>/` | **29 GB** | `dera download` |
| 2 | EDGAR bulk submissions archive | `data/edgar/submissions.zip` | **1.5 GB** | `dera fetch-filing-index` |
| 3 | SEC company-ticker crosswalk + Internet Archive | `data/reference/ticker_history.csv` | 11 MB | `tools/fetch_ticker_history.py` |
| 4 | Wikipedia S&P index pages | `data/reference/sp1500_universe.csv` | 102 KB | `tools/fetch_sp1500.py` |
| 5 | NYSE trading calendar | `data/reference/trading_calendar.csv` | 256 KB | `tools/build_calendar.py` |

Plus a small set of hand-maintained files described under [Manual inputs](#manual-inputs).

---

## 1. SEC DERA Financial Statement Data Sets

**The fundamentals.** Every number in the silver and gold layers originates here.

- **URL**: `https://www.sec.gov/files/dera/data/financial-statement-data-sets/<year>q<n>.zip`
- **Coverage**: 2009q1 → 2026q2, **70 quarters**
- **Shape**: four tab-separated files per quarter — `sub` (submissions), `num`
  (numeric facts), `tag` (taxonomy), `pre` (presentation)
- **Licence**: US government work, public domain
- **Becomes**: `sec_raw.{sub,tag,num,pre}_raw` → `sec_silver.*` → `sec_gold.*`

**The critical limitation, and the reason source 2 exists:** DERA publishes only
filings that carry XBRL *financial statements*. Verified against the live
database — `sec_silver.sub_silver` contains **zero** Form 25, Form 15 or 8-A. So
listings and delistings, which is to say the entire lifecycle of a security, are
simply not in this dataset. No amount of work on these tables recovers them.

Two known data quirks, both published by SEC as-is and both handled downstream:
filer typos put `value_date`s between 1980 and 2031, and `segments` values
occasionally contain embedded tabs.

## 2. EDGAR bulk submissions archive

**The security lifecycle.** Every filing every filer has ever made, as JSON.

- **URL**: `https://www.sec.gov/Archives/edgar/daily-index/bulkdata/submissions.zip`
- **Size**: 1.5 GB, **989,015 members**
- **Becomes**: `sec_reference.security_event_raw` → `security`, `listing`,
  `delisting_event`

We read only the ~17,000 CIKs that appear in `sec_reference.company`; the rest of
EDGAR is noise for this purpose. The zip's central directory makes named lookups
cheap, so members are read individually rather than by walking the archive.

**Watch out for pagination.** `filings.recent` caps at 1000 entries, and the
overflow members under `filings.files` must be read too. Apple's `recent` reaches
back only to 2015 while its 8-A is older, so skipping overflow silently loses the
listing evidence for exactly the long-lived companies you most want.

**Do not use the `tickers` field as a universe.** It is current-state, so it is
survivorship-biased in precisely the way this project exists to remove. SVB
Financial — an S&P 500 member until 2023 — returns `"tickers": []`. Its *filing
history*, however, is intact and dated. That asymmetry is why the security spine
is built from filing events and never from any file describing the present.

## 3. SEC company-ticker crosswalk, replayed through the Internet Archive

**The CIK ↔ ticker map, de-survivorshipped as far as free data allows.**

- **Live**: `https://www.sec.gov/files/company_tickers.json`
- **History**: Wayback snapshots of that same URL, first capture **2019-02**
- **Becomes**: `sec_reference.ticker_observation` → `company_ticker`

SEC deletes companies from this file when they delist and publishes no history,
so today's file is missing 58.5% of 2013 filers and 36.1% of 2019 filers. Wayback
replay recovers some of it — the 2019-02 snapshot alone returns 2,473 CIKs absent
from the live file.

**The floor is 2019-02 and it is load-bearing.** Companies that delisted between
2009 and 2019 remain unrecoverable from free sources. This is why tickers before
2019 are labelling fallbacks flagged with `ticker_is_asof = false` rather than
date-correct symbols. Closing the gap needs a vendor with delisted coverage.

## 4. Wikipedia S&P index constituent pages

**Today's S&P 1500 membership**, and the only free path to historical membership.

- **Pages**: `List_of_S&P_{500,400,600}_companies`
- **Becomes**: `sec_silver.universe_sp1500` (current membership only, **no dates**)

Historical membership would come from replaying page revisions. That is not yet
built, and the coverage limit is worth recording because it is not what you would
guess — the constraint is **not revision depth** but whether the page carried a
CIK column:

| Index | Real CIK column | Ticker + name only |
|---|---|---|
| S&P 500 | 2014 → now | 2009–2013 |
| S&P 400 | **never**, including the 2026 page | 2011 → now |
| S&P 600 | 2019 → now | — |

The 2009 S&P 500 page's "SEC filings" link reads `CIK=MMM` — a *ticker* in an
EDGAR URL that accepts either. Also measured: ~1.6% of revisions are malformed
(one 309-byte anonymous edit, reverted within five minutes, truncated the parsed
table from 506 companies to 370), and a removed ticker survives in the page text
for months inside the changes table, so any diff must run against the
`id="constituents"` table alone.

## 5. NYSE trading calendar

- **Becomes**: `sec_reference.trading_calendar` (4,947 sessions)

Used to turn an EDGAR acceptance timestamp into the first session on which a fact
was actually actionable. 57% of filings (247,216 of 433,717) are accepted after
the close and stamped that same `filed_date`; 210,683 of them roll to a later
session.

## Manual inputs

| File | Rows | What it is |
|---|---|---|
| `share_class_map.csv` | 27 across 9 CIKs | Hand-mapped share class → ticker, each citing its filing |
| `tickers.csv` | — | Legacy CIK ↔ ticker crosswalk, manually replaced |
| `GAAP Taxonomy 2024.xlsx` | — | Reference taxonomy, not loaded by the pipeline |
| `revenue_labels*.xlsx` | — | Scratch analysis of revenue tag labels |

---

## Provenance: how far back a number traces

The database is deliberately strong on this **inside** the pipeline and weak at
the **acquisition boundary**. Both halves are worth knowing.

### What is fully traceable

Every fact in `sec_gold.fact_asof` carries `adsh`, `form` and `filed_date`, so any
figure resolves to a single EDGAR accession number and from there to the document
that reported it. Because the model is bitemporal, it also carries `known_at`,
`tradable_from` and `superseded_tradable` — you can recover not just what was
reported but when it became knowable and what later replaced it. GE's fiscal 2022
revenue exists as four distinct vintages across three values, each attributable.

The `sec_reference` tables carry per-row provenance by design:

| Table | Provenance columns |
|---|---|
| `share_class` | `source` (`mapped_filing`/`mapped_exchange`/`mapped_vendor`), `source_note` |
| `security` | `source`, `source_detail`, plus `first_trade_basis` recording the *evidence class* |
| `delisting_event` | `source_form`, `source_adsh` |
| `listing` | `source` (`share_class_map` / `company_ticker`) |

`first_trade_basis` deserves note: it distinguishes an 8-A listing registration
from a 424B pricing from `already_reporting` (a conservative upper bound used when
the company was public before EDGAR existed) from a bare `first_edgar_filing`.
Those are not equally strong claims and the column refuses to blend them.

### Where provenance is currently missing

Honest gaps, all at the acquisition boundary:

- **`sp1500_universe.csv` records no Wikipedia revision id and no capture date.**
  There is no way to reproduce the scrape that produced a given file, or to tell
  how stale it is.
- **`tickers.csv` is replaced by hand with no date stamp.**
- **`data/raw/` quarters are not checksummed.** `sec_raw.load_log` records which
  quarters were loaded, but not what their contents hashed to, so a silently
  re-issued quarter would not be detected.
- **The xlsx reference files have no recorded origin or date.**

None of these are hard to fix and none are fixed yet. The pattern to follow is
`wayback_stamps.json`, which does exactly the right thing for source 3: it records
the specific archived captures a run resolved to, so the run is reproducible.

---

## Refreshing everything

```bash
uv run dera download --from 2026q2 --to 2026q2   # new DERA quarter
uv run dera load --quarter 2026q2                # into bronze
uv run dera build-silver                         # ~39 min, single transaction
uv run dera build-gold                           # ~16 min
uv run dera verify                               # correctness suite

uv run dera fetch-filing-index                   # EDGAR archive, ~1.5 GB
uv run dera build-security-model                 # security lifecycle

uv run python tools/fetch_ticker_history.py      # resumes; run repeatedly
uv run python tools/fetch_sp1500.py              # S&P membership
```
