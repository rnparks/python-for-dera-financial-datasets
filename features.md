# DERA Research Platform — Feature Roadmap

A living document that tracks what exists, what's partial, and what's planned. The goal: any future session can pick an item and execute it without re-deriving context.

**Last updated**: 2026-09-04
**Branch**: `db_update`
**Maintainer**: Ryan Parks

---

## Status snapshot

Postgres medallion pipeline (`sec_raw` → `sec_silver` → `sec_gold` →
`sec_reference`) over SEC DERA Financial Statement Data Sets,
2009q1 → 2026q2, 185M num rows, 138 GB.

**Usable today**:
- Bronze/silver/gold end-to-end. `run-all` no longer destroys a populated bronze; that needs `--reinit-bronze`.
- **Bitemporal point-in-time correctness.** `sec_gold.fact_asof` keeps every vintage of every fact with `known_at`, `tradable_from` and `superseded_tradable`. An as-of slice is an indexed interval scan returning exactly one row per fact. Verified on GE fiscal 2022 revenue, which has **four** vintages, not two: $76.555B as first filed 2023-02-10, restated to $58.100B by an 8-K on 2023-04-25, reaffirmed 2024-02-02, then $29.139B on 2025-02-03.
- **Availability, not filing date.** `tradable_from` is derived from the EDGAR acceptance timestamp against a real NYSE calendar. 48% of filings are accepted after the close yet stamped that same `filed_date`; all 247,216 now roll to a later session.
- **As-of accessors** where the knowledge date has no default, so omitting it is an error rather than a silent leak: `as_of_facts`, `as_of_canonical`, `as_of_latest_annual`, `as_of_snapshot`. `p_buffer_sessions` applies a safety margin in trading sessions.
- **Survivorship-free company spine.** `sec_reference.company` holds every CIK that ever filed; `company_ticker` gives dated ticker intervals with `is_primary`. Recovered 2013 10-K filer coverage from 36% to 80%.
- **Derived concepts.** `concept_formula` computes `gross_profit`, `free_cash_flow` and `total_debt` from other concepts. `total_debt` no longer understates.
- **Peer stats at two GICS levels** in one table tagged by `peer_level`; sector scores all 1,569 companies where sub-industry dropped 147.
- 15-check verification suite in `tools/verify_pit.sql`.
- **Security lifecycle model (Phase 0 slice, 18 CIKs).**
  `sec_reference.{security,listing,eligibility,delisting_event,corporate_action,company_name}`
  separate a company from the securities it issues. `universe_at(name, asof)`
  reconstructs a historical universe with no default knowledge date. The 2015
  universe contains SIVB, SHLD, TWTR and BBBY under their era tickers and
  excludes Palantir, Coinbase and Rivian. 27/27 checks pass.

**Missing for serious research**:
- **Prices.** Still the biggest gap and nothing else is testable without it. The share-count denominator already exists (`shares_outstanding_at`, availability-correct) — prices are the only missing input.
- **Point-in-time universe.** Solved in principle and proven on an 18-CIK
  slice (see above); needs the bulk EDGAR filing index to scale to all 17,015
  CIKs. `universe_sp1500` is still today's membership with no dates, and gold
  still joins to it.
- **Historical index membership.** Not started. Free coverage is bounded by
  whether Wikipedia's page carried a CIK column: S&P 500 from 2014, S&P 600
  from 2019, S&P 400 **never**. Revision depth is not the constraint.
- **Delisting returns.** `delisting_event.delisting_return` is declared and
  NULL for all 7 delisted securities. It needs prices, and it is the reason
  this is not yet a reliable backtester.
- **Multi-class market cap.** Denominator now built: `sec_gold.share_class_shares` gives per-class counts for mapped issuers, and `share_classes_at(cik, asof)` returns one row per class. 177 of 1,500 issuers hold multiple listed tickers, 131 file multiple common classes. Remaining: the class-to-ticker mapping covers only 9 companies by hand so far. A cover-page scraper can derive the rest exactly — every 10-K since 2019 carries `dei:TradingSymbol` dimensioned by `StatementClassOfStockAxis`, whose member string matches `num_silver.segments` character for character.
- Scale-free metrics: margins, ROIC, FCF yield, growth. `concept_formula` is the mechanism; nothing uses it for ratios yet.
- Factor library — requires prices.
- Incremental silver rebuild. Full rebuild is now ~39 min and is a single transaction, so a late failure discards everything.
- No test runner or CI. `verify_pit.sql` is invoked from nothing.
- Form 13F / Form 4, research SDK, parquet exports.
- Long-tail XBRL tag coverage for company-extension namespaces.

---

## Shipped

In reverse chronological order on `refactor/medallion-cleanup`:

- `113f66d` — feat(gold): add peer_zscore_by_sub_industry matview + broaden revenue tags
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
>    `shares_outstanding_at` already ladders five tags to 99.5%.
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
CREATE TABLE sec_gold.prices (
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
CREATE INDEX idx_prices_date ON sec_gold.prices (trade_date);

CREATE MATERIALIZED VIEW sec_gold.market_cap_daily AS
SELECT p.ticker, p.trade_date, p.close,
       s.shares_outstanding,
       p.close * s.shares_outstanding AS market_cap
FROM sec_gold.prices p
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
- `sec_gold.market_cap_daily` has one row per (ticker, trade_date) with PIT market cap
- Spot checks: AAPL 2020-03-23 (COVID bottom) close, NVDA 2024-06-18 post-split, BRK.A vs BRK-B handled

**Loader**: `dera_pipeline/prices.py` with `download_polygon_flat_file(date)` + `load_price_file(conn, path)` using `cur.copy("COPY sec_gold.prices ...")`. CLI: `dera fetch-prices --from 2009-01-01 --to $(date +%Y-%m-%d)`.

**Effort**: 1-2 days after Polygon.io signup.

---

### Incremental silver rebuild

**Problem**: `dera build-silver` currently runs `CREATE TABLE num_silver AS ...` which is a full rebuild of all 177M rows (~32 minutes). Adding a single new quarter (2026q1 when it drops in mid-April) shouldn't cost 32 minutes.

**Approach**:
1. Add new quarter to `sec_raw.num_raw` via `dera load --quarter` (works today).
2. Compute silver rows for just the new quarter into a staging table.
3. `MERGE INTO sec_silver.num_silver USING staging ON (adsh, tag, ...) WHEN MATCHED ... WHEN NOT MATCHED INSERT`.
4. Recompute `rank_pit` / `rank_latest` only for partitions where the staging table introduced rows — a small subset of the full universe.

**Acceptance criteria**:
- `dera load --quarter 2026q1 && dera build-silver --incremental` completes in under 5 minutes.
- Row counts in silver after incremental build match what a full rebuild would produce (check on a sample of 100 partitions).
- `rank_pit` values for historical quarters are unchanged (no look-ahead contamination from the new data).

**Risk**: The window function `ROW_NUMBER() OVER (PARTITION BY ...)` needs to be recomputed for any partition that got a new row. If the partition is (cik, tag, value_date, qtrs, uom, coreg, segments), a new filing for CIK X with tag Y and value_date Z only affects partitions with exactly those values — small fan-out.

**Effort**: 4-6 hours. Requires careful testing.

---

### Derived QoQ / YoY / TTM metrics

**Problem**: Growth rates are central to both quant factors and fundamental analysis, and computing them at query time over 177M rows is slow. Pre-compute once per silver rebuild.

**Proposed matview**:
```sql
CREATE MATERIALIZED VIEW sec_gold.fundamentals_growth AS
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

**Problem**: Systematic quant strategies want a single `sec_gold.factors_monthly` table with pre-computed factor ranks at each month-end for every S&P 1500 ticker.

**Proposed table**:
```sql
CREATE MATERIALIZED VIEW sec_gold.factors_monthly AS
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

### Sub-day accepted_time in num_silver

**Problem**: `num_silver.filed_date` is a `DATE`, losing the intraday precision captured in `sub_silver.accepted_time` (`TIMESTAMPTZ`). For intraday backtests ("did I know X at 10:05 AM when the 10-Q dropped at 10:03 AM?") we need sub-day resolution.

**Approach**:
1. Add `accepted_time TIMESTAMPTZ` column to `sec_silver.num_silver`.
2. Populate it during silver build via `JOIN sub_silver USING (adsh)` — we already do that join.
3. Update `rank_pit` / `rank_latest` ORDER BY to use `accepted_time` before `filed_date` as the tiebreaker.

**Acceptance**: Query for a known intraday filing (e.g., AAPL Q2 earnings released after close) returns rows with non-midnight timestamps.

**Effort**: 30 minutes of SQL + one full silver rebuild (~32 min).

---

### Revenue from components (for banks without single-tag revenue)

**Problem**: Some large banks (USB, TFC in S&P 500) don't file a single `Revenues`, `RevenuesNetOfInterestExpense`, or similar headline revenue tag. They file only decomposed components: `InterestIncomeExpenseNet` + `NoninterestIncome`. Today those banks are missing from `sec_gold.peer_stats` for the revenue concept. NOTE: `concept_formula` now exists and is the mechanism for this — bank revenue can be declared as a sum of its components rather than needing new code.

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

**Approach**: `dera export --matview peer_stats --output s3://bucket/path` — dumps a gold matview to a partitioned parquet file using psycopg + pyarrow.

**Effort**: 2-3 hours.

---

### Data quality monitors

**Problem**: A silent bad value can pollute research for months. We need proactive detection.

**Approach**: `sec_gold.magnitude_anomalies` matview that flags any value >100× the peer median for the same (concept, fiscal_year, sub_industry). Plus temporal self-consistency (value >10× a company's own trailing 4-year median).

**Acceptance**: Daily run surfaces <50 new anomalies per quarter; most are real data errors, not real outliers.

**Effort**: 4-6 hours.

---

### Earnings calendar (filing dates + surprise)

**Problem**: Event-driven strategies need to know when earnings were *released*, not just when the 10-Q was received by SEC. And they want the analyst consensus + reported surprise.

**Source**:
- Filing dates: already in `sub_silver.accepted_time`.
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

**Problem**: We have Sector (11) and Sub-Industry (163) today. Industry Group (25) and Industry (74) are missing.

**Approach**: Hardcode a 163-row `sec_gold.gics_hierarchy(sub_industry_name, industry_name, industry_group_name, sector_name)` table from S&P's public GICS taxonomy structure. Derivative from public structure, no licensing risk. View `sec_gold.sp1500_gics_full` left-joins universe_sp1500 to the hierarchy.

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

**Approach**: Extract MD&A section via regex, embed with sentence-transformers, persist as `sec_gold.mda_embeddings`. Compute quarter-over-quarter cosine similarity as a "management tone change" signal.

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
3. Commit `features.md` alongside the feature commit.

**When blocked**:
1. Add a note under the blocked item explaining the blocker.
2. Propose an alternative approach or escalate to the user.
