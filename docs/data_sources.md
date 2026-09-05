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

**Observed coverage starts 2018-12 and is back-extended for one shape.** The
first full-size capture is 2019-10-02, so every pair alive then is
left-censored. Where a CIK has had exactly one primary ticker in its whole
observed history (preferred lines and notes are non-primary and do not count; a
ticker change does — Meta is FB then META and gets nothing), that ticker was
seen on or before the floor, the company filed before the first sighting, and no
other CIK was seen holding the ticker earlier in the window, the spine writes
one `source = 'extended'` interval from `company.first_filed` to the first
sighting. As of 2026-09-04 that is **6,405 CIKs** (2,108 of them already
delisted when first seen; 86 candidates skipped because a stale file still
showed the ticker against a predecessor, Alcoa Inc against AA). Extended rows
are inferences: `ticker_is_asof`, `price_ticker_is_asof` and `universe_at`'s
flag are true for observed intervals only, and their listings carry
`source = 'company_ticker_extended'`. The 2015 universe went from 2,420
unlabelled members to 1,476, and `cik_at('AAPL', DATE '2015-06-30')` resolves.
Companies that delisted between 2009 and 2018 and never appeared in the file,
and any ticker that changed before 2018-12, remain unrecoverable from free
sources; closing that needs a vendor with delisted coverage.

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

**Today's S&P 1500 membership, and dated membership for all three indexes,
replayed from each page's revision history: the S&P 500 since 2008, the S&P 400
since 2011, the S&P 600 since 2018.**

- **Pages**: `List_of_S&P_{500,400,600}_companies`
- **Today**: `tools/fetch_sp1500.py` → `sec_silver.universe_sp1500` (no dates)
- **History**: `tools/fetch_sp500_history.py [--index SP400|SP600]` →
  `data/reference/sp{500,400,600}_history.csv.gz` → `sec_reference.index_observation`
  → `index_sighting` → `index_membership`

The history tool asks the MediaWiki API for the latest revision at the start of
each month from October 2008 and parses the rendered constituents table: **214
captures**, 107,555 constituent sightings, table sizes 496–505 (no capture was
undersized; the same 85%-of-window rule as the crosswalk stands guard anyway).
Because the page carried GICS sector on every revision and sub-industry from
2016, the classification is **as of** for the first time.

**CIK resolution, per run.** A ticker present in consecutive captures is one
company for that whole run, and the run gets one CIK from three sources, in
order, recorded in `cik_source`. The **page**'s CIK column — where it exists
(S&P 500 from 2014, S&P 600 from 2018-10, S&P 400 never) and only if the value
is a CIK that has ever filed, since the S&P 1000-era S&P 600 page carried most
CIKs with an extra trailing zero (73320 for Southwestern Energy's 7332) and AAR
Corp as 17500 in 13 captures. Then SEC's own dated **crosswalk**,
`cik_at(ticker, last sighting)`, which outranks a page CIK it disagrees with and
resolves the S&P 400 almost entirely (56,086 of its 61,201 sightings; Sonoco,
First American, Rayonier, Crane, AGCO all failed a name match). Then the
**name**, normalised, matching exactly one company the spine has ever known
under any name and that was filing at the time. Measured 2026-09-04 across the
three indexes: 150,851 sightings from the page, 59,100 by crosswalk, 3,539 by
name; **138 tickers unresolved** (953 sightings: S&P 500 38, S&P 400 14, S&P 600
86), listed in `sec_reference.index_membership_unresolved` and never guessed.
The S&P 500's 2009-06-30 cross-section resolves 497 of its members; 822
companies have been in it since 2008 against 503 on today's page.

**Granularity.** Membership starts at the page's own "date added" where it has
one (Tesla: 2020-12-21), else the first monthly capture, and ends at the first
capture that no longer lists the company. A mid-month replacement therefore
overlaps by up to a month, so a cross-section can count a few more than 500
(518 on 2015-06-30). The page's "changes" table has exact dates and is the
obvious refinement.

**The other two indexes.** The S&P 400 page (153 monthly captures from
2011-01, always 400 rows) has never carried a CIK column; the crosswalk
resolves it, and it covers 391 of 400 members in mid-2012 and 399 in 2024. The
S&P 600 page (92 captures from 2018-08) needed two findings. From its first
revision until 2021-02 it was the **S&P 1000**: measured on 2019-06-22, 994
rows of which 395 were on that month's S&P 400 page and 599 were not, so for an
S&P 600 capture over 700 rows a ticker the closest S&P 400 capture (within 45
days) also lists is removed — `sec_reference.index_sighting` is
`index_observation` after that rule, and `index_observation` stays the raw
record. The subtraction is only as good as the two pages' agreement: it holds
from 2018-11 through 2019 (596–597 of 600) and fails as the pages drift apart
(620–756 rows from 2019-12 to 2021-02), so a capture whose remainder is not
within 570–615 rows is unused and partial, and through that gap
`index_membership` carries only the 444 members seen on both sides — an
honest under-count rather than a 75%-right list. From 2021-03 the page is a
plain list of the 600 and membership is exact. Also measured: ~1.6% of S&P 500
revisions are malformed (one 309-byte anonymous edit truncated the table from
506 companies to 370), and a removed ticker survives for months in a page's
changes table, so only the constituents table is read.

| Index | Captures | Page CIK column | Resolved by | Coverage |
|---|---|---|---|---|
| S&P 500 | 214, 2008-09 → | 2014 → | page; crosswalk and name before | 500–505 members on every mid-year date |
| S&P 400 | 153, 2011-01 → | never | crosswalk (92%), page, name | 390–400 |
| S&P 600 | 92, 2018-08 → | 2018-10 → (unreliable to 2021-02) | page, crosswalk | 596–600, except 444 through the 2020 gap |

**CIK succession.** A holding-company reorganisation gives a company a new
CIK, and the index pages know only one CIK per ticker, so a run resolved to
one registrant named either a CIK that did not exist yet (APA Corp 1841666 for
Apache 6769 before 2021) or one that had stopped filing (Cigna 701221 after
2018): five S&P 500 constituents of 2020-06-30 had no filer behind them.
`sec_reference.cik_succession` records the ticker handoffs in SEC's own file —
a primary ticker whose interval for one CIK ends where a newer CIK's begins,
211 pairs — and the spine splits a membership interval that straddles a
handoff, re-keying the earlier part to the old registrant (32 intervals). What
tells succession from a recycled ticker is unbroken index presence across the
handoff; a recycled ticker changes company only after a removal, which ends
the run. Not caught: a ticker change at succession (Paramount Global PARA →
Paramount Skydance PSKY, 2025) and handoffs before the crosswalk's 2018-12
start where neither registrant's ticker is back-extended.

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
`first_pricing_date` exists so a stricter universe can prefer it, and
`filers_10k_15m_strict` does: an `already_reporting` security enters at that
pricing when one exists later. Measured 2026-09-04 on the 2015-06-30 universe,
216 of 7,298 members move out, 59 of them companies that filed before 1998 and
were therefore public before EDGAR, whose later 424B is a follow-on. The strict
universe is late-but-proven, the base one early-but-inclusive.

### Where provenance is currently missing

Honest gaps, all at the acquisition boundary:

- **`sp1500_universe.csv` records no Wikipedia revision id and no capture date.**
  There is no way to reproduce the scrape that produced a given file, or to tell
  how stale it is.
- **`tickers.csv` is replaced by hand with no date stamp.**
- **`data/raw/` quarters are not checksummed.** `sec_raw.load_log` records which
  quarters were loaded and every bronze row carries its `source_quarter`, but
  nothing records what the files hashed to, so a silently re-issued quarter
  would not be detected (it can at least be replaced: `dera load --quarter Q
  --force`).
- **The xlsx reference files have no recorded origin or date.**

None of these are hard to fix and none are fixed yet. The pattern to follow is
`wayback_stamps.json`, which does exactly the right thing for source 3: it records
the specific archived captures a run resolved to, so the run is reproducible.

---

## Refreshing everything

```bash
uv run dera download --from 2026q3 --to 2026q3   # new DERA quarter
uv run dera load --quarter 2026q3                # into bronze; --force replaces a loaded quarter
uv run dera build-silver --quarter 2026q3        # fold: only the fact partitions it touches are recomputed (~17 min)
uv run dera rebuild-reference                    # spine, security model, gold matviews whose inputs changed
uv run dera verify                               # correctness suite

uv run dera build-silver                         # the full rebuild, ~39 min: first build or a re-issued dataset
uv run dera build-gold                           # ~26 min

uv run dera fetch-filing-index                   # EDGAR archive, ~1.5 GB
uv run dera build-security-model                 # security lifecycle

uv run python tools/fetch_ticker_history.py --batch 0   # all captures + live file
uv run python tools/fetch_sp500_history.py --batch 0    # S&P 500 revisions (resumes)
uv run python tools/fetch_sp1500.py              # today's S&P 1500
uv run python tools/fetch_cover_page_classes.py --sp500 --write-map   # dual-class mappings
uv run dera rebuild-reference                    # CSVs -> spine (in place) -> security model -> refresh what changed
```

A crosswalk, membership or mapping refresh always ends with `rebuild-reference`.
The fetch tools write files, never the database, so it reloads these files
first, then refills the spine in place and refreshes only the gold matviews
whose inputs changed.
