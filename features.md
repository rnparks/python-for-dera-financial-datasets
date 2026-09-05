# DERA Research Platform — Feature Roadmap

A living document that tracks what exists, what's partial, and what's planned. The goal: any future session can pick an item and execute it without re-deriving context.

**Last updated**: 2026-09-04
**Branch**: `main` (work lands via short-lived branches such as `review-fixes`)
**Maintainer**: Ryan Parks

---

## Status snapshot

Postgres medallion pipeline (`sec_raw` → `sec_silver` → `sec_gold` →
`sec_reference`) over SEC DERA Financial Statement Data Sets,
2009q1 → 2026q2, 185M num rows, 139 GB.

**All figures in this file are as of 2026-09-04.**

**Usable today**:
- Bronze/silver/gold end-to-end. `run-all` no longer destroys a populated bronze; that needs `--reinit-bronze`. `dera load` refuses a quarter that is already in `sec_raw.load_log`, and `--full` requires `--truncate`, because bronze has no quarter column and a second COPY simply doubled the rows.
- **Bitemporal point-in-time correctness.** `sec_gold.fact_asof` keeps every vintage of every fact with `known_at`, `tradable_from` and `superseded_tradable`. An as-of slice is an indexed interval scan returning exactly one row per fact. Verified on GE fiscal 2022 revenue, which has **four** vintages, not two: $76.555B as first filed 2023-02-10, restated to $58.100B by an 8-K on 2023-04-25, reaffirmed 2024-02-02, then $29.139B on 2025-02-03.
- **Availability, not filing date.** `tradable_from` is derived from the EDGAR acceptance timestamp against a real NYSE calendar. 57% of filings (247,216 of 433,717) are accepted after the close; 48% of all filings (209,441) still carry that day's `filed_date`. 433 filings are actionable *before* their `filed_date` (accepted after 5:30 pm on the eve of a federal holiday NYSE trades through). `docs/data_sources.md` has the full breakdown.
- **As-of accessors** where the knowledge date has no default, so omitting it is an error rather than a silent leak: `as_of_facts`, `as_of_canonical`, `as_of_latest_annual`, `as_of_snapshot` (by CIK or by ticker). `p_buffer_sessions` applies a safety margin in trading sessions. The silent-empty paths are gone: `financials('asof')` without a date, `shift_sessions` before the calendar, and a ticker the crosswalk cannot resolve on the date all **raise**.
- **Derived concepts resolve everywhere.** `concept_formula` computes `gross_profit`, `free_cash_flow` and `total_debt`; both `latest_annual` and `as_of_latest_annual` fall back to it and the newest period wins over a stale direct tag. `total_debt` resolves for 1,127 of 1,127 tracked companies that `peer_stats` scores for FY2024 (was 256 before the formula, 1,063 before the 2026-09-04 tag additions); Apple's snapshot reads $82.7B at 2026-03-31, not $40.1B at 2015-03-31.
- **Revenue before ASC 606.** `SalesRevenueNet` and its siblings are mapped; FY2015 revenue covers 1,283 of 1,361 tracked issuers (was 628), FY2010 1,105 (was 552).
- **Survivorship-free company spine.** `sec_reference.company` holds every CIK that ever filed; `company_ticker` gives dated ticker intervals with `is_primary`, built from **81 monthly archive captures** (2018-12 to 2026-09) of SEC's ticker file. 12,321 of 20,326 CIKs with an interval are absent from SEC's live file. A capture is evidence of presence, never proof of absence on its own: 18 undersized captures are flagged in `sec_reference.ticker_capture` and short silences are bridged. A company that has only ever had one primary ticker is extended back to its first filing (`source = 'extended'`, 6,405 CIKs), and every as-of flag downstream is true for observed intervals only.
- **Security lifecycle model — 17,025 listed securities.** `sec_reference.{security,listing,eligibility,delisting_event,corporate_action,company_name}` separate a company from the securities it issues, built from 905,049 EDGAR filing events across 17,015 CIKs. Form types are matched whole (a prefix match once read Regulation A circulars as Form 25). 7,119 outcomes: 4,498 exchange notices, 2,621 deregistrations (companies that went dark without a Form 25 and had no outcome row before). `universe_at('filers_10k_15m','2015-06-30')` returns **7,293 members, 3,012 of them (41%) since delisted or deregistered** — a current-constituents universe returns none.
- **Multi-class market cap denominator, decided from the filings.** A single-class issuer is one that has never reported share counts for two `ClassOfStock` members, so preferreds, baby bonds and delistings no longer exclude anyone (Bank of America with seventeen tickers is single-class) and dual-class issuers with an unlisted second class (Meta, Nike, Visa) are no longer priced on an unverified 1:1. Dual-class issuers need a cited mapping: `tools/fetch_cover_page_classes.py` derives it from the issuer's own 10-K cover page, and 57 S&P 500 issuers are mapped that way alongside the 9 by hand (99 rows, every one citing its filing). 482 of today's 500 constituents have per-class counts; the denominator covers 9,654 companies overall. `share_classes_at(cik, asof)` returns one row per class with `price_ticker_is_asof`.
- **Dated S&P 500 membership, and gold reads it.** `sec_reference.index_membership` is replayed from 214 monthly Wikipedia captures since 2008 (840 companies ever in the index against 503 today; 40 early tickers unresolved and listed), with GICS as of the interval. The two `tradable_financials` matviews carry `index_name`, `index_is_asof` and as-of GICS per fact, and `peer_stats` scores only facts whose company was a constituent when the fact became actionable, so a FY2012 cross-section is 2012's index. `universe_at('sp500', date)` (508 securities on 2015-06-30) and `index_members('SP500', date)` expose it; the FY2012 peer panel holds 476 S&P 500 companies, FY2024 499. The S&P 400 and 600 remain today's snapshot, labelled `current_snapshot`, until their histories are replayed.
- **Peer stats at two GICS levels** in one table tagged by `peer_level`, with `index_name` on every row.
- **Margins, returns, leverage and growth, with peer scores.** `sec_gold.concept_ratio` defines 11 scale-free concepts (gross/operating/net/FCF margin, ROE, ROA, debt-to-equity, and year-over-year growth of revenue, net income, diluted EPS and operating cash flow) as ratios of concepts at one period or of one concept over its prior fiscal year. A non-positive denominator or base is NULL, never a number. `peer_stats` scores them with the same moments and percentiles as the dollar concepts (FY2024: net margin for 1,401 companies, revenue growth 1,420); `latest_annual`, `as_of_latest_annual` and both snapshots resolve them, so the 26-concept snapshot works as of any date. Check 55 pins Apple, NVIDIA and a Boeing NULL.
- **A strict filer universe.** `filers_10k_15m_strict` is `filers_10k_15m` with one change: a security whose first trade is known only from its first periodic report enters at its first 424B1/424B4 pricing when one exists later (1,832 intervals; 7,082 members on 2015-06-30 against 7,298, 6,837 against 6,868 in 2024). Every strict interval lies inside a base interval and never before the pricing (check 54); Plymouth Industrial REIT is the named case, reporting from 2011 and priced 2017-06-09.
- **Cross-section balances are fiscal year-end balances.** A `peer_stats` balance row is admitted only on a date the company also reports an annual period for; before this, 91% of FY2024 balance rows (6,739 of 7,378) were Q1 10-Q balances because `fiscal_year_of` puts a March period end in the prior year and the latest date won. JPMorgan's FY2024 debt is now the 2024-12-31 figure (401B), Apple's FY2024 assets the September one. Two companies without a FY2024 10-K (Marathon Oil, BlackRock's old registrant) drop out of FY2024 rather than showing a quarter's balance.
- **S&P 500 concept gaps closed where the filings allow.** 24 us-gaap debt tags (two more totals, six noncurrent and seven current lines: JPMorgan's 401B is `LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities`, Goldman's 243B `UnsecuredLongTermDebt`, Oracle's 85B `LongTermNotesAndLoans`) take FY2024 `total_debt` from 414 to 436 of the 502 members of 2024-12-31 and from 1,063 to 1,127 tracked issuers; the noncurrent operand is now required, so the 26 totals that were the current portion alone (Deere) are NULL instead of wrong. Revenue rows for non-bank lenders (SIC 61) and REIT lease income take FY2024 revenue to 500 of 502; APA files only custom tags. Still unresolved by design: 16 REITs (secured/unsecured pairs), asset managers, and issuers that tag debt by segment.
- **Gold joins a non-overlapping membership timeline.** `sec_reference.index_membership_timeline` resolves `index_membership` once per company (replayed history beats a snapshot, then the later start; an EXCLUDE constraint forbids overlap) and the three membership-reading matviews join it with a plain range condition instead of a per-fact LATERAL. Full gold build 32 → 25:42 min (2026-09-04); `fact_asof` is 19:36 of that; its bare query runs in 64 s (three hash joins over 97.9M rows), so the remainder is Postgres writing its 22 GB heap and 10 GB of indexes, and a redundant cik-only index (653 MB) is gone. `run_sql_dir` prints each file's seconds.
- **55-check verification suite** in `tools/verify_pit.sql`, run by `dera verify` (~90 s); checks 29–55 each name the 2026-09-04 review defect, or the gap closed since, that they guard. Plus 102 unit tests (`uv run pytest`, no database) and GitHub Actions running `ruff` and `pytest` on every push.
- **Doc-staleness checker.** `dera verify-docs` validates every database object name — in prose and inside SQL examples — file path, CLI command and cross-link in the Markdown against the live repo and database.
- **`dera rebuild-reference` refreshes what changed.** It reloads the reference CSVs (the fetch tools never write the database, and this stage was missing), refills the spine in place so the gold matviews survive, rebuilds the security model and refreshes only the matviews whose inputs changed, decided by digesting the spine tables before and after: a crosswalk change refreshes four matviews and leaves the 33 GB `fact_asof` alone (about 6 minutes end to end), a mapping change refreshes one, and nothing changed means nothing refreshed (52 seconds). Every spine rebuild used to drop gold with CASCADE and cost a 32-minute rebuild. `build-silver` without the filing index preserves the security model instead of emptying it.

**Missing for serious research**:
- **Prices.** Still the biggest gap and nothing else is testable without it. The share-count denominator exists (`share_class_shares`, availability-correct, delisted issuers included) — prices are the only missing input.
- **S&P 400 and 600 membership is still today's snapshot.** Their Wikipedia pages carry a CIK column only from 2019 (600) or never (400), so `index_membership` holds them as one labelled interval from 1900-01-01 and cross-sections restricted to them still carry survivorship bias. Replaying the 600 from 2019 is the same tool with a different page; the 400 needs ticker-and-name resolution against the crosswalk, which the S&P 500 replay already does for 2008–2013.
- **No knowledge-date peer cross-section.** `peer_stats` is an as-now-understood fiscal-year panel, and its `tradable_from` is the restated vintage's date (97% of FY2024 revenue rows carry the following year's comparative), so it cannot be lagged for a backtest. The backtest object is a cross-section at a date T built from `fact_asof`: each member's latest annual flows and latest balance sheet knowable at T, staleness alongside, membership as of T, moments over what was knowable. Listed as item 8b.
- **Forty pre-2014 S&P 500 tickers are unresolved** (`sec_reference.index_membership_unresolved`), 21 of them inside DERA coverage: J.C. Penney, Sunoco, Washington Post, the two Viacoms. Name normalisation or a hand table would close them. Membership dates are month-granular; the page's "changes" table has exact dates.
- **Pre-2019 ticker labels, the remainder.** The back-extension took the 2015 universe from 2,420 unlabelled members to 1,476 and made `cik_at('AAPL', DATE '2015-06-30')` resolve; 65 of the 518 S&P 500 members of mid-2015 still have no ticker for that date. What is left is a company that delisted before 2018-12 and never appeared in SEC's file, or a ticker that changed before then (Meta was FB, and the ticker-keyed `as_of_snapshot` raises for it; use the CIK overload). Dating ticker changes from 8-K Item 5.03 filings, or a vendor with delisted coverage, would close it.
- **`already_reporting` is early for some issuers, and only a stricter universe can avoid it.** 52.5% of securities date their first trade from the first periodic report; 1,738 of them carry a 424B pricing after it. `filers_10k_15m_strict` enters those at the pricing, which is right for OTC micro-caps and non-traded REITs and late for a pre-EDGAR listed company whose 424B was a follow-on (59 of the 216 that leave the 2015 universe). Filings cannot tell the two apart; a listing-history vendor could.
- **Dual-class issuers outside the S&P 500 are unmapped.** roughly 2,100 companies in the spine have reported two or more share-class members; 66 are mapped. The cover-page tool works for any CIK with an inline-XBRL 10-K (`--cik`), so extending it to the 400 and 600 is a run, not a design. Six S&P 500 covers say only "Common Stock" against A/B members (Blackstone, CDW, Domino's, Interactive Brokers, Zoetis, Quanta) and unlisted classes (Meta B, Nike A, Visa B/C) need a cited conversion ratio before their market caps are complete.
- **Historical index membership.** Not started. Free coverage is bounded by
  whether Wikipedia's page carried a CIK column: S&P 500 from 2014, S&P 600
  from 2019, S&P 400 **never**. Revision depth is not the constraint.
- **Delisting returns.** `delisting_event.delisting_return` is declared and
  NULL for all **7,119** outcomes. It needs prices, and it is the reason
  this is not yet a reliable backtester. The business cause of an outcome
  (acquisition, bankruptcy) is not derived either; `reason` records only the
  evidence class.
- **Multi-class mapping, remaining.** The cover-page scraper exists and is the way in; what remains is running it beyond the S&P 500 and citing conversion ratios for unlisted classes.
- Scale-free metrics that need a market value (FCF yield, earnings yield) or invested capital (ROIC). Margins, ROE/ROA, leverage and year-over-year growth shipped 2026-09-04 through `concept_ratio`.
- Factor library — requires prices.
- Incremental silver rebuild. Full rebuild is ~39 min and is a single transaction, so a late failure discards everything. A bronze `quarter` column is the prerequisite (and would also allow a single quarter to be replaced).
- Form 13F / Form 4, research SDK, parquet exports.
- Long-tail XBRL tag coverage for company-extension namespaces.

---

## Shipped

In reverse chronological order. The 2026-09-04 review landed as six commits; the S&P 500 membership, share-class and ticker back-extension work followed the same day.

- (this commit) — feat(gold): margins, returns, leverage and year-over-year growth as concepts, scored in peer_stats and resolved by every snapshot
- `b72d4e3` — feat(security): filers_10k_15m_strict, a universe that enters a reporting-before-listing issuer at its first priced offering
- `8e25dc7` — fix(gold): peer_stats balance concepts take the fiscal year-end balance, not the latest quarter inside the window
- `1b1fb40` — feat(gold): close the S&P 500 total_debt and revenue gaps with 24 us-gaap tags; require the noncurrent operand so a total is never the current portion alone
- `efcf4a0` — perf(gold): a non-overlapping membership timeline replaces the per-fact LATERAL in the three membership-reading matviews
- `722aaed` — perf(reference): refill the spine in place; rebuild-reference reloads the CSVs and refreshes only the matviews whose inputs changed
- `c14ea0e` — feat(spine): back-extend single-ticker histories before the archive floor; every as-of ticker flag is observed-only
- `5e7cbde` — feat(reference,gold): dated S&P 500 membership from Wikipedia revisions; share classes decided by the filings and mapped from 10-K cover pages
- `7947ee4` — docs: reconcile every document with the 2026-09-04 review — every number re-measured and date-stamped; the 48%-vs-57% contradiction resolved
- `1c4ca96` — test: 42-check verify suite, 82 unit tests, CI
- `65a70d2` — fix(pipeline): reload guard, computed default quarter, 404 handling, doc-checker blind spots, dead indexes
- `4a91330` — fix(gold): derived-concept fallback in both lookup families, strict tickers, delisted issuers in the share denominator, pre-2018 revenue
- `c856c88` — fix(security): anchored form classification, Form 15 outcomes, listed classes only, no lost listings
- `ce49406` — fix(crosswalk): monthly captures, no fabricated live snapshot, capture-quality gap bridging

- `705b2c0` — chore: add the pre-commit doc-staleness hook
- `4510fbe` — docs: make the doc-currency rule explicit and enforceable
- `b0526d3` — docs: eliminate documentation staleness and add a checker that prevents it
- `2e0f84d` — docs: bring README and architecture current; add schema overview
- `7f69d99` — feat(reference): scale the security model to 17,031 securities
- `39fe460` — feat(reference): security lifecycle model; separate company from security
- `11b5967` — feat(gold): per-share-class counts; fix two class-summing defects
- `34379aa` — feat(gold): derived-concept mechanism; fix total_debt understatement
- `4698a5a` — perf(gold): join ticker instead of per-row call; add GICS; two-level peer_stats
- `3eedd5f` — test: add PIT verification suite; rebuild silver and gold
- `a05ac89` — feat(silver,gold): bitemporal facts, as-of accessors, crosswalk fan-out fix
- `0aacf2f` — fix: seven correctness and safety defects from external code review
- `5de661f` — feat(pit): filing-availability foundation and survivorship-free crosswalk

- `113f66d` — feat(gold): add peer_zscore_by_sub_industry matview + broaden revenue tags <!-- check-docs:ignore renamed to peer_stats in 4698a5a -->
- `5bfd54f` — feat(gold): fiscal-year-aware latest_annual + snapshot, fix capex tag
- `b4e5299` — feat(gold): add canonical_concepts + get_canonical() function
- `4e9ae82` — feat(reference): capture GICS sector and sub-industry for S&P 1500
- `df546f8` — fix(cli,silver): skip redundant gold REFRESH; size work_mem for num_silver
- `7606a2d` — fix(loader): commit per quarter so load_all is incremental and visible
- `89a34ce` — fix(loader,gold): handle embedded tabs in segments; bypass function in matviews
- `ffb3c61` — docs: rewrite README for medallion pipeline, add architecture.md
- `61bae13` — chore: relocate tree, delete legacy scripts, update gitignore
- `e658f9f` — refactor(sql): reorganize into bronze/silver/gold/reference tree
- `98dc2a5` — feat(python): add dera CLI entry point
- `cd9f7d3` — chore: switch from pip/requirements.txt to uv-managed pyproject.toml
- `fd61e71` — feat(python): add psycopg3-based bronze loader
- `f44d4e4` — feat(python): add dera_pipeline package skeleton

### Resolved by the 2026-09-04 review, for the record

- **The dropped listing intervals are explained.** Of 26,277 candidate intervals on the old crosswalk, 2,988 lay outside the security's life; 2,938 were tickers first observed *after* the delisting (2,209 of those delistings predate the 2019 floor, only 4 of the companies filed anything a year later) and 50 were "ticker gone before first trade". SEC's file carries dead entries for years — the June 2020 purge removed 7,879 at once — so this was never a late `first_trade_date`.
- **The old "current" crosswalk snapshot was the December 2025 local file stamped with the run date** (an exact set match). It resurrected 1,334 retired tickers as current, Electronic Arts among them. The fallback is gone.
- **Partial archive captures manufactured 2,459 false ticker gaps**; the spine now flags them and bridges short silences.

---

## Tier 2 — In scope, not yet started

### Price + market cap pipeline

**Problem**: Fundamentals without prices is close to useless for quant research. You can't compute P/E, EV/EBITDA, momentum, size, returns, or point-in-time market cap without a daily price history.

**Recommended source**: **Polygon.io S3 flat files** — `s3://flatfiles.polygon.io/us_stocks_sip/day_aggs_v1/` gives one CSV per trading day with every US ticker. ~$29/month, bulk-downloadable, adjusted for splits. Handles the "yfinance doesn't scale" constraint.

**Alternative**: Tiingo EOD API ($10-30/mo, adjusted daily bars, broader history than free tiers). Less bulk-friendly but cheaper.

> **WARNING — do not build the matview below as written.** It has three
> defects, all fixed by work that landed after this section was drafted:
>
> 1. `rank_latest = 1` is the *restated* share count, pulled from a future
>    filing. This is precisely the look-ahead the bitemporal work removed.
>    Use `sec_gold.fact_asof` with the `tradable_from` / `superseded_tradable`
>    interval, or simply call `sec_gold.shares_outstanding_at(cik, asof)`.
> 2. It hardcodes `EntityCommonStockSharesOutstanding`, which covers 69%.
>    `shares_outstanding_at` already ladders five tags to 99.5% (1,490 of
>    1,498). The 69% figure actually measured `CommonStockSharesOutstanding`,
>    a different tag.
> 3. It joins `ticker_map`, which is survivorship-biased. Use
>    `sec_reference.cik_at(ticker, asof)`.
>
> The fourth defect, **multi-class issuers**, is now addressed on the share
> side. `sec_gold.share_class_shares` holds per-class counts and
> `share_classes_at(cik, asof)` returns one row per class with the ticker whose
> price applies. So the price loader should be keyed on **(ticker, trade_date)
> where ticker is a listed share class**, and market cap is
> `SUM(shares * price(price_ticker))` across the classes a company returns.
>
> Note an unlisted class such as Alphabet Class B carries
> `prices_with_ticker` rather than a ticker of its own, so it needs a price
> lookup against its reference class rather than being skipped.

**Proposed schema** (superseded — see warning above):
```sql
CREATE TABLE sec_gold.prices (   -- check-docs:ignore proposed, does not exist yet
    ticker       TEXT NOT NULL,
    trade_date   DATE NOT NULL,
    open         NUMERIC(12,4),
    high         NUMERIC(12,4),
    low          NUMERIC(12,4),
    close        NUMERIC(12,4),
    adj_close    NUMERIC(12,4),   -- split/dividend adjusted
    volume       BIGINT,
    PRIMARY KEY (ticker, trade_date)
);
CREATE INDEX idx_prices_date ON sec_gold.prices (trade_date);   -- check-docs:ignore proposed, does not exist yet

CREATE MATERIALIZED VIEW sec_gold.market_cap_daily AS   -- check-docs:ignore proposed, does not exist yet
SELECT p.ticker, p.trade_date, p.close,
       s.shares_outstanding,
       p.close * s.shares_outstanding AS market_cap
FROM sec_gold.prices p   -- check-docs:ignore proposed, does not exist yet
JOIN LATERAL (
    -- Point-in-time shares outstanding: most recent value as of trade_date
    SELECT dei_so.value AS shares_outstanding
    FROM sec_silver.num_silver dei_so
    WHERE dei_so.cik = (SELECT cik FROM sec_silver.ticker_map WHERE ticker = p.ticker)
      AND dei_so.tag = 'EntityCommonStockSharesOutstanding'
      AND dei_so.value_date <= p.trade_date
      AND dei_so.rank_latest = 1
    ORDER BY dei_so.value_date DESC LIMIT 1
) s ON TRUE;
```

**Acceptance criteria**:
- Daily OHLCV for every S&P 1500 ticker from 2009-01-02 → current trading day
- Adjusted close populated for every row
- `sec_gold.market_cap_daily` has one row per (ticker, trade_date) with PIT market cap <!-- check-docs:ignore proposed, does not exist yet -->
- Spot checks: AAPL 2020-03-23 (COVID bottom) close, NVDA 2024-06-18 post-split, BRK.A vs BRK-B handled

**Loader**: `dera_pipeline/prices.py` with `download_polygon_flat_file(date)` + `load_price_file(conn, path)` using `cur.copy("COPY sec_gold.prices ...")`. CLI: `dera fetch-prices --from 2009-01-01 --to $(date +%Y-%m-%d)`. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 1-2 days after Polygon.io signup.

---

### Incremental silver rebuild

**Problem**: `dera build-silver` currently runs `CREATE TABLE num_silver AS ...` which is a full rebuild of all 185M rows (~39 minutes). Adding a single new quarter (2026q1 when it drops in mid-April) shouldn't cost 32 minutes.

**Approach**:
1. Add new quarter to `sec_raw.num_raw` via `dera load --quarter` (works today).
2. Compute silver rows for just the new quarter into a staging table.
3. `MERGE INTO sec_silver.num_silver USING staging ON (adsh, tag, ...) WHEN MATCHED ... WHEN NOT MATCHED INSERT`.
4. Recompute `rank_pit` / `rank_latest` only for partitions where the staging table introduced rows — a small subset of the full universe.

**Acceptance criteria**:
- `dera load --quarter 2026q3 && dera build-silver --incremental` completes in under 5 minutes. <!-- check-docs:ignore proposed flag -->
- Row counts in silver after incremental build match what a full rebuild would produce (check on a sample of 100 partitions).
- `rank_pit` values for historical quarters are unchanged (no look-ahead contamination from the new data).

**Risk**: The window function `ROW_NUMBER() OVER (PARTITION BY ...)` needs to be recomputed for any partition that got a new row. If the partition is (cik, tag, value_date, qtrs, uom, coreg, segments), a new filing for CIK X with tag Y and value_date Z only affects partitions with exactly those values — small fan-out.

**Effort**: 4-6 hours. Requires careful testing.

---

### Derived QoQ / YoY / TTM metrics

**Status 2026-09-04**: year-over-year growth of revenue, net income, EPS and operating cash flow ships in `peer_stats` and the snapshot functions via `concept_ratio` (fiscal-year aligned, positive base, consecutive years only). What remains of this proposal is quarter-over-quarter and trailing-twelve-month, which need quarterly (`qtrs = 1`) resolution that the canonical layer does not do yet.

**Problem**: Growth rates are central to both quant factors and fundamental analysis, and computing them at query time over 185M rows is slow. Pre-compute once per silver rebuild.

**Proposed matview**:
```sql
CREATE MATERIALIZED VIEW sec_gold.fundamentals_growth AS   -- check-docs:ignore proposed, does not exist yet
WITH base AS (
    SELECT ticker, cik, concept, fiscal_year, value_date, value
    FROM sec_gold.peer_stats  -- renamed; filter peer_level
)
SELECT
    b.*,
    LAG(value, 1) OVER (PARTITION BY cik, concept ORDER BY value_date) AS value_prev_period,
    LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date) AS value_prior_year,
    (value - LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date))
        / NULLIF(LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date), 0)
        AS yoy_growth,
    AVG(value) OVER (PARTITION BY cik, concept ORDER BY value_date ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS ttm_avg
FROM base b
WHERE concept IN ('revenue','gross_profit','operating_income','net_income','operating_cash_flow');
```

**Acceptance**: Query `WHERE ticker = 'NVDA' AND concept = 'revenue'` returns 15+ years of YoY growth rates with correct values (e.g., NVDA FY2025 revenue $130.5B vs FY2024 $60.9B → yoy_growth = 114%).

**Requires**: canonical_concepts layer (Tier 1, done).

**Effort**: 2-3 hours.

---

### Factor library (monthly cadence)

**Problem**: Systematic quant strategies want a single `sec_gold.factors_monthly` table with pre-computed factor ranks at each month-end for every S&P 1500 ticker. <!-- check-docs:ignore proposed, does not exist yet -->

**Proposed table**:
```sql
CREATE MATERIALIZED VIEW sec_gold.factors_monthly AS   -- check-docs:ignore proposed, does not exist yet
SELECT
    ticker, month_end,
    -- Size
    log(market_cap) AS log_mcap,
    -- Value
    market_cap / NULLIF(trailing_revenue, 0) AS ps_ratio,
    market_cap / NULLIF(trailing_net_income, 0) AS pe_ratio,
    (market_cap + total_debt - cash) / NULLIF(trailing_ebitda, 0) AS ev_ebitda,
    -- Quality
    trailing_net_income / NULLIF(total_equity, 0) AS roe,
    trailing_net_income / NULLIF(total_assets, 0) AS roa,
    total_debt / NULLIF(total_equity, 0) AS debt_equity,
    -- Growth
    yoy_revenue_growth, yoy_earnings_growth,
    -- Momentum
    (close / close_12m_ago - 1) AS return_12m,
    (close / close_1m_ago  - 1) AS return_1m,
    -- Composite
    percent_rank() OVER (PARTITION BY month_end ORDER BY ...) AS value_rank,
    ...
FROM ...;
```

**Requires**: prices (Tier 2), canonical concepts (Tier 1, done), peer z-scores (Tier 1, done), derived growth metrics (Tier 2).

**Acceptance**: Run a naive "top-decile value" backtest in SQL against this table — should match published factor returns within ~50 bps/year over 2010-2024.

**Effort**: 1-2 days after prices land.

---

### ~~Sub-day accepted_time in num_silver~~ — DONE

**This item was already delivered under a different column name.** There is no
`sub_silver.accepted_time`; the acceptance instant is `known_at TIMESTAMPTZ`, and
`num_silver` carries it too (values span 2009-04-15 16:44 EDT → 2026-06-30 17:30
EDT). Intraday questions are answerable today. Retained only so nobody re-plans it.

**Original problem statement**: `num_silver.filed_date` is a `DATE`, losing the intraday precision captured in the submission record. For intraday backtests ("did I know X at 10:05 AM when the 10-Q dropped at 10:03 AM?") we need sub-day resolution.

**Approach**:
1. Add `accepted_time TIMESTAMPTZ` column to `sec_silver.num_silver`.
2. Populate it during silver build via `JOIN sub_silver USING (adsh)` — we already do that join.
3. Update `rank_pit` / `rank_latest` ORDER BY to use `accepted_time` before `filed_date` as the tiebreaker.

**Acceptance**: Query for a known intraday filing (e.g., AAPL Q2 earnings released after close) returns rows with non-midnight timestamps.

**Effort**: 30 minutes of SQL + one full silver rebuild (~39 min).

---

### Revenue from components (for banks without single-tag revenue)

**Problem**: Some large banks (USB, TFC in S&P 500) don't file a single `Revenues`, `RevenuesNetOfInterestExpense`, or similar headline revenue tag. They file only decomposed components: `InterestIncomeExpenseNet` + `NoninterestIncome`. **RESOLVED**: both now resolve in `sec_gold.peer_stats` — USB revenue FY2023–FY2025 is $30.0B / $31.7B / $31.0B and TFC $24.5B / $25.1B / $24.5B. Retained for the general pattern only.

**Fix**: Add a "derived revenue" computed as `InterestIncomeExpenseNet + NoninterestIncome` when no headline tag is available. Priority 5 in concept_tag_map, or a separate fact_type='derived_bank_revenue' concept.

**Affected tickers**: USB, TFC, a handful of smaller regional banks.

**Effort**: 1-2 hours. Needs either a derived-concept mechanism in get_canonical or a pre-computed view.

---

## Tier 3 — Later

### Form 13F (institutional holdings)

**Source**: SEC publishes 13F filings quarterly in a separate DERA dataset at `https://www.sec.gov/files/dera/data/form-13f/` (different from the Financial Statement Data Sets we already load). Contains every 13F filer's holdings above $100M AUM.

**Tables**: `sec_13f.filings`, `sec_13f.holdings(filer_cik, issuer_cusip, shares, value, quarter)`.

**Use cases**: ownership crowdedness, hedge fund tilt analysis, "who bought what this quarter" event signals.

**Effort**: 1 day — new bronze pipeline, parse SEC XML format.

---

### Form 4 (insider trades)

**Source**: SEC EDGAR full-text search API or bulk XML feeds. Not in DERA — requires scraping or using an EDGAR SDK.

**Tables**: `sec_insiders.transactions(cik, reporter_cik, transaction_date, code, shares, price_per_share, direct_indirect)`.

**Use cases**: insider buying/selling signals, cluster buying detection.

**Effort**: 1-2 days. Form 4 XML parsing is non-trivial.

---

### Python research SDK (`dera_pipeline.research`)

**Problem**: SQL is verbose for notebook-style research. A small Python layer would make the common patterns (screen, compare, backtest) one-liners.

**Proposed API**:
```python
from dera_pipeline.research import Screen, Company, Peer

# Screen for value + quality
candidates = Screen(universe='SP500', as_of='2024-12-31')
    .where(concept='pe_ratio', zscore_lt=-0.5)      # cheap vs peers
    .where(concept='roe', zscore_gt=0.5)             # quality vs peers
    .top(20)

# Deep dive
aapl = Company('AAPL')
print(aapl.snapshot())              # canonical concepts
print(aapl.peer_rank('revenue'))    # vs semiconductors sub-industry
print(aapl.history('revenue', years=10))
```

**Effort**: 1 day for a minimal v1 with 3 classes.

---

### Parquet export layer

**Problem**: Some research workflows are pandas/polars-native and want data in parquet files, not Postgres connections.

**Approach**: `dera export --matview peer_stats --output s3://bucket/path` — dumps a gold matview to a partitioned parquet file using psycopg + pyarrow. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 2-3 hours.

---

### Data quality monitors

**Problem**: A silent bad value can pollute research for months. We need proactive detection.

**Approach**: `sec_gold.magnitude_anomalies` matview that flags any value >100× the peer median for the same (concept, fiscal_year, sub_industry). Plus temporal self-consistency (value >10× a company's own trailing 4-year median). <!-- check-docs:ignore proposed, does not exist yet -->

**Acceptance**: Daily run surfaces <50 new anomalies per quarter; most are real data errors, not real outliers.

**Effort**: 4-6 hours.

---

### Earnings calendar (filing dates + surprise)

**Problem**: Event-driven strategies need to know when earnings were *released*, not just when the 10-Q was received by SEC. And they want the analyst consensus + reported surprise.

**Source**:
- Filing dates: already in `sub_silver.known_at` (the acceptance instant) and `tradable_from`.
- Press release timestamps: company IR pages or scraping 8-K filings for the `99.1` earnings exhibit.
- Analyst estimates: IBES/Zacks (licensed) or free aggregators like Zacks public API.

**Effort**: 3-4 hours for filing dates; additional 1-2 days for full surprise metrics.

---

### Backtest harness

**Problem**: We have data but not a way to test a strategy end-to-end.

**Proposed**: minimal `dera_pipeline.backtest` module:
```python
def run(universe, signal_fn, weight='equal', rebalance='monthly',
        start='2010-01-01', end=None, costs_bps=5):
    ...
    return BacktestResult(returns, turnover, metrics)
```

Uses the factor library for signals, the price layer for returns. Not a replacement for Zipline/Backtrader — just enough to sanity-check a factor.

**Effort**: 2-3 days.

---

### GICS Phase B (Industry Group + Industry levels)

**Problem**: We have Sector (11) and Sub-Industry (156 present in this universe; 163 in the full GICS taxonomy) today. Industry Group (25) and Industry (74) are missing.

**Approach**: Hardcode a 163-row `sec_gold.gics_hierarchy(sub_industry_name, industry_name, industry_group_name, sector_name)` table from S&P's public GICS taxonomy structure. Derivative from public structure, no licensing risk. View `sec_gold.sp1500_gics_full` left-joins universe_sp1500 to the hierarchy. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 1-2 hours.

---

### Russell 3000 universe expansion

**Problem**: S&P 1500 covers ~1,500 names. Russell 3000 is ~3,000. Adds small-caps we currently can't screen.

**Approach**: Source from Russell's reconstitution announcements (public, scraped) or FTSE's API. Most of the code that reads universe_sp1500 today takes `WHERE` clauses, so adding a parallel `universe_russell3000` table is mostly additive.

**Catch**: Russell doesn't publish GICS for their constituents — we'd need to either accept missing GICS for non-S&P names or find a secondary source.

**Effort**: 3-4 hours.

---

### 10-K / earnings call transcript text analytics

**Problem**: A huge amount of alpha is in the management commentary section of 10-Ks and earnings call transcripts — sentiment, complexity, changes in tone quarter-over-quarter.

**Source**:
- 10-K text: SEC EDGAR raw filings (free but messy HTML).
- Transcripts: Seeking Alpha (scrape, gray area) or paid providers (AlphaSense, Sentieo).

**Approach**: Extract MD&A section via regex, embed with sentence-transformers, persist as `sec_gold.mda_embeddings`. Compute quarter-over-quarter cosine similarity as a "management tone change" signal. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: Multi-day research project.

---

## Rejected / out of scope

- **yfinance for prices** — doesn't scale, unreliable.
- **IBES/Zacks analyst estimates** — expensive licensing, not worth it for a personal research setup.
- **Alternative data (credit card, satellite, web scrape)** — expensive, specialized, low ROI vs. fundamental research.
- **Options data** — different asset class, out of scope.
- **Bond-level data** — different asset class, out of scope.
- **Amending the refactor branch commits** — always create new commits, never force-push.

---

## How to use this document

**When starting a new session**, read:
1. "Status snapshot" — what's working today.
2. "Shipped" — recent commits in case something changed.
3. Pick an item from Tier 2 or Tier 3 and read its full spec.

**When shipping a new feature**:
1. Move the item from "Tier 2/3" to "Shipped" with the commit hash.
2. Update "Status snapshot" if the feature unlocks new capabilities.
3. Update every other doc the change touches — see the table in `CLAUDE.md`.
   `README.md`, `docs/architecture.md`, `docs/schema_overview.md`,
   `docs/gold_tables.md` and `docs/data_sources.md` are all expected to be
   current at every commit, not periodically caught up.
4. Run `uv run dera verify-docs` and `uv run dera verify`.
5. Commit the docs alongside the feature, never afterwards.

**When blocked**:
1. Add a note under the blocked item explaining the blocker.
2. Propose an alternative approach or escalate to the user.
