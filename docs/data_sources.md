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
| 3 | SEC company-ticker crosswalk + Internet Archive | `data/reference/ticker_history.csv.gz` | 15 MB | `tools/fetch_ticker_history.py` |
| 4 | Wikipedia S&P index pages, today and (S&P 500) every month since 2008 | `data/reference/sp1500_universe.csv`, `sp500_history.csv.gz` | 102 KB, 0.7 MB | `tools/fetch_sp1500.py`, `tools/fetch_sp500_history.py` |
| 4b | Issuer 10-K cover pages (inline XBRL) | `data/reference/share_class_map.csv`, `cover_page_classes.csv` | small | `tools/fetch_cover_page_classes.py` |
| 5 | NYSE trading calendar | `data/reference/trading_calendar.csv` | 256 KB | `tools/build_calendar.py` |

Plus a small set of hand-maintained files described under [Manual inputs](#manual-inputs).

---

## 1. SEC DERA Financial Statement Data Sets

**The fundamentals.** Every number in the silver and gold layers originates here.

- **URL**: `https://www.sec.gov/files/dera/data/financial-statement-data-sets/<year>q<n>.zip`
- **Coverage**: 2009q1 → 2026q2, **70 quarters**. The default end quarter is the
  last fully elapsed calendar quarter, computed from today's date; a quarter SEC
  has not published yet answers 404 and is reported once, not retried.
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
- **Becomes**: `sec_reference.security_event_raw` (905,049 classified events
  across 17,015 CIKs) → `security`, `listing`, `delisting_event`

We read only the ~17,000 CIKs that appear in `sec_reference.company`; the rest of
EDGAR is noise for this purpose. The zip's central directory makes named lookups
cheap, so members are read individually rather than by walking the archive.

**Form types are matched whole, not by prefix.** The classifier in
`dera_pipeline/filings.py` once matched `form.startswith("25")`, which swallowed
`253G1`–`253G4` — Regulation A offering circulars, a capital raise — as delisting
notices; 771 events were misread and 54 securities were "delisted" on the day
they raised money. The patterns are now anchored (`^25(-NSE)?(/A)?$` and so on)
and `dera verify` check 29 asserts that every delisting outcome traces to a Form
25 or Form 15.

**Two outcome evidence classes.** A Form 25 is an exchange removal notice; a
Form 15 (`15-12B`, `15-12G`, `15-15D` and the `15F-` foreign variants) ends the
reporting obligation. Either counts as the end of the security only if the
company then actually stopped reporting — the going-concern gates in
`sql/06_security/010_security_populate.sql`. Admitting Form 15 gave 2,621
companies that went dark without an exchange delisting an outcome row; before,
they had none.

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
- **History**: Wayback captures of that same URL, probed monthly; the archive's
  first capture is **2018-12-26**
- **File**: `data/reference/ticker_history.csv.gz`, 861,755 observations across
  **81 captures** (80 archived + one live fetch dated 2026-09-04), one row per
  (cik, ticker, capture). Gzipped because the plain file passed 60 MB.
- **Becomes**: `sec_reference.ticker_observation` → `ticker_capture` →
  `company_ticker`

SEC deletes companies from this file when they delist and publishes no history,
so today's file is missing 58.5% of 2013 filers and 36.1% of 2019 filers. Wayback
replay recovers a great deal of it: **12,321 of the 20,326 CIKs** with a ticker
interval are absent from the live file.

**The floor is 2019 and it is load-bearing.** Companies that delisted between
2009 and 2018 remain unrecoverable from free sources. This is why tickers before
2019 are labelling fallbacks flagged with `ticker_is_asof = false` rather than
date-correct symbols. Closing the gap needs a vendor with delisted coverage.

**A capture is evidence of presence, not proof of absence.** SEC's file is not a
stable list and the archive's captures of it are not all complete. Three shapes
were measured on the 81 captures:

| When | What the file did | Verdict |
|---|---|---|
| June 2020 | fell from 13,633 rows to 8,223; 7,879 pairs never seen again | a genuine purge of stale entries — their absence is real |
| May–September 2023 | sat near 9,000 rows for five months, then 10,886 | artefact: 1,148 pairs vanished on 2023-05-02 and came back in October |
| October–November 2021 | ~900 pairs gone for two captures, back in January 2022 | same shape, shorter |

Read as complete lists, these captures manufactured 2,459 false "ticker retired"
gaps, and inside each gap `cik_at()` returned NULL. Two rules in
`sql/05_spine/010_company_spine.sql` handle them: a capture holding fewer than
85% of the largest capture within six either side is **partial** (18 of 81 are;
`sec_reference.ticker_capture` records which), and a silence between two
sightings of the same pair is **bridged** when the pair is seen again within 200
days or every capture in the silence is partial. When a pair never reappears,
`valid_to` is the first capture it was absent from, whatever that capture's
quality — the June 2020 purge is the case that proves that is right.

**The live file is fetched or it is not written.** An earlier version of the tool
fell back to the local `tickers.csv` when the live fetch failed and stamped those
rows with the run date as `sec_current`. The database then carried a nine-month-
old file labelled as the present, resurrecting 1,334 retired tickers (Electronic
Arts, since taken private, among them) as "still current". The fallback is gone;
a failed live fetch is reported and the run carries no live snapshot. Check 31
asserts the newest capture is a recent live fetch.

## 4. Wikipedia S&P index constituent pages

**Today's S&P 1500 membership, and — for the S&P 500 — dated membership since
2008, replayed from the page's revision history.**

- **Pages**: `List_of_S&P_{500,400,600}_companies`
- **Today**: `tools/fetch_sp1500.py` → `sec_silver.universe_sp1500` (no dates)
- **History**: `tools/fetch_sp500_history.py` → `data/reference/sp500_history.csv.gz`
  → `sec_reference.index_observation` → `index_membership`

The history tool asks the MediaWiki API for the latest revision at the start of
each month from October 2008 and parses the rendered constituents table: **214
captures**, 107,555 constituent sightings, table sizes 496–505 (no capture was
undersized; the same 85%-of-window rule as the crosswalk stands guard anyway).
Because the page carried GICS sector on every revision and sub-industry from
2016, the classification is **as of** for the first time.

**CIK resolution.** The page has a CIK column only from 2014. Earlier rows are
resolved three ways, in order, each recorded in `cik_source`: the page itself;
**continuity** — a ticker present in every capture from the row up to the first
capture with a CIK is the same company, since a recycled ticker shows a removal
and a later re-addition; and the **name**, normalised, matching exactly one
company the spine has ever known under any name and that was filing at the time.
Measured: 74,743 sightings from the page, 28,851 by continuity, 3,373 by name;
**40 tickers unresolved** (588 sightings), 21 of them ending inside DERA coverage
— Sunoco, J.C. Penney, Washington Post, Viacom's two Viacoms — listed in
`sec_reference.index_membership_unresolved` and never guessed. The 2009-06-30
cross-section resolves 497 of its members; 840 companies have been in the index
since 2008 against 503 on today's page.

**Granularity.** Membership starts at the page's own "date added" where it has
one (Tesla: 2020-12-21), else the first monthly capture, and ends at the first
capture that no longer lists the company. A mid-month replacement therefore
overlaps by up to a month, so a cross-section can count a few more than 500
(518 on 2015-06-30). The page's "changes" table has exact dates and is the
obvious refinement.

The coverage limit for the other two indexes is not revision depth but whether
the page carried a CIK column:

| Index | Real CIK column | Ticker + name only |
|---|---|---|
| S&P 500 | 2014 → now | 2008–2013 (resolved as above) |
| S&P 400 | **never**, including the 2026 page | 2011 → now |
| S&P 600 | 2019 → now | — |

Until those are replayed, `index_membership` carries the 400 and 600 as a single
interval from 1900-01-01 with `source = 'current_snapshot'` — the old
survivorship-biased state, confined to two indexes and labelled. Also measured:
~1.6% of revisions are malformed (one 309-byte anonymous edit truncated the
table from 506 companies to 370), and a removed ticker survives for months in
the page's changes table, so only the constituents table is read.

## 4b. Issuer 10-K cover pages (share-class mapping)

- **Source**: each dual-class issuer's latest 10-K primary document on EDGAR,
  located through the bulk submissions archive
- **Tool**: `tools/fetch_cover_page_classes.py`
- **Becomes**: candidate rows for `data/reference/share_class_map.csv` →
  `sec_reference.share_class`; every cover line is recorded in
  `data/reference/cover_page_classes.csv`

Since 2019 the cover page tags `dei:TradingSymbol`, `dei:SecurityExchangeName`
and `dei:Security12bTitle` in inline XBRL, and the `StatementClassOfStockAxis`
member on those facts is exactly what DERA renders into `num_silver.segments`.
Where an issuer registers a single class it tags the symbol in the default
context and names the class in the 12(b) title ("Class B Common Stock" for Nike),
which is matched to the one member carrying that class's share counts. Spelling
changes (BFA → BF-A) and renames (FB → META, SQ → XYZ) become dated rows from the
crosswalk's own intervals. Measured on the dual-class S&P 500 issuers (two or more class members on the
three point-in-time share-count tags): 72 cited mapping rows across 57 issuers;
a dozen covers say only "Common Stock" against A/B members (Blackstone, CDW,
Domino's, Interactive Brokers, Zoetis, Quanta, Cboe, EOG, Generac and others)
and are reported for a hand decision. Unlisted classes are never mapped by the tool:
they need a conversion ratio the cover does not state.

## 5. NYSE trading calendar

- **Becomes**: `sec_reference.trading_calendar` (4,947 sessions, 2009-01-02 to
  2028-09-01)

Used to turn an EDGAR acceptance timestamp into the first session on which a fact
was actually actionable. Measured on 433,717 filings:

| | Filings | Share |
|---|---:|---:|
| Accepted at or after 16:00 ET | 247,216 | 57.0% |
| Accepted after that session's actual close, or on a non-session day | 247,376 | 57.0% |
| …of which stamped with that same day's `filed_date` | 209,441 | 48.3% |
| …of which stamped with the next business day (EDGAR's 5:30 pm rule) | 37,923 | 8.7% |
| `tradable_from` later than `filed_date` | 210,683 | 48.6% |
| `tradable_from` earlier than `filed_date` | 433 | 0.1% |

The last row is not an error: those filings were accepted after 5:30 pm on the
eve of Columbus Day or Veterans Day, when NYSE trades but EDGAR is closed, so
`filed_date` rolled forward while the market did not. Both directions are why
`tradable_from`, never `filed_date`, is the availability key.

The loader refuses a calendar with less than a year left (`reference.py`), and
check 38 asserts the loaded one reaches at least 180 days past the newest
filing, because a filing accepted after the last session would get a NULL
`tradable_from` and vanish from every as-of query without a message.

## Manual inputs

| File | Rows | What it is |
|---|---|---|
| `share_class_map.csv` | 99 across 66 CIKs | Share class → ticker allowlist: 27 hand-mapped rows citing filings, 72 derived from 10-K cover pages by `tools/fetch_cover_page_classes.py` |
| `tickers.csv` | 10,221 | Legacy CIK ↔ ticker crosswalk (December 2025). Loads `sec_silver.ticker_map` only; no longer a fallback for anything |
| `wayback_stamps.json` | — | The archive captures the last crosswalk run resolved to, keyed by the probe set that produced them |
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
| `security` | `source`, `source_detail`, `first_trade_basis` (the evidence class) and `first_pricing_date` (the earliest 424B pricing, kept as evidence) |
| `delisting_event` | `reason` (`exchange_notice` or `deregistration`: the evidence class), `source_form`, `source_adsh` |
| `listing` | `source` (`share_class_map` / `company_ticker`) |
| `ticker_capture` | `n_rows`, `window_max`, `is_partial` — why a capture's silences were or were not trusted |

`first_trade_basis` deserves note: it distinguishes an 8-A listing registration
from a 424B pricing from `already_reporting` from a bare `first_edgar_filing`.
Those are not equally strong claims and the column refuses to blend them.
`already_reporting` (52.5% of securities) is late-but-true for a company public
before EDGAR existed and **early** for one that reported before its equity
traded; filings alone cannot tell those apart. Measured: 1,755 of them carry a
424B pricing after their `first_trade_date`, 1,100 more than three years after.
`first_pricing_date` exists so a stricter universe can prefer it.

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
uv run dera load --quarter 2026q2                # into bronze (refuses a quarter already loaded)
uv run dera build-silver                         # ~39 min, single transaction
uv run dera build-gold                           # ~16 min
uv run dera verify                               # correctness suite

uv run dera fetch-filing-index                   # EDGAR archive, ~1.5 GB
uv run dera build-security-model                 # security lifecycle

uv run python tools/fetch_ticker_history.py --batch 0   # all captures + live file
uv run python tools/fetch_sp500_history.py --batch 0    # S&P 500 revisions (resumes)
uv run python tools/fetch_sp1500.py              # today's S&P 1500
uv run python tools/fetch_cover_page_classes.py --sp500 --write-map   # dual-class mappings
uv run dera rebuild-reference                    # spine -> security model -> gold
```

A crosswalk, membership or mapping refresh always ends with `rebuild-reference`:
rebuilding the spine drops the gold matviews, so the three stages have to run in
that order.
