# DERA Research Platform — Feature Roadmap

A living document that tracks what exists, what's partial, and what's planned. The goal: any future session can pick an item and execute it without re-deriving context.

**Last updated**: 2026-04-11
**Branch**: `refactor/medallion-cleanup`
**Maintainer**: Ryan Parks

---

## Status snapshot

The platform is a Postgres medallion pipeline (`sec_raw` → `sec_silver` → `sec_gold`) over SEC DERA Financial Statement Data Sets, 2009q1 → 2025q4, 177M num rows.

**Usable today**:
- Bronze/silver/gold end-to-end (`dera init-db → load → build-silver → build-gold`)
- Point-in-time correctness via `rank_pit` / `rank_latest` (verified against GE FY2022 restatement — $76.5B original → $29.1B restated, both preserved)
- GICS Sector + Sub-Industry on every S&P 1500 ticker (sourced from Wikipedia, 100% coverage)
- Canonical concept layer: `sec_gold.canonical_concepts` (12 concepts) + `concept_tag_map` (~28 rows) + `get_canonical(cik, concept, date, qtrs, mode)` — verified to match 10-K dollar-for-dollar against Nike/Apple/BAC/Meta/UNP
- Fiscal-year-aware: `sec_gold.latest_annual_by_ticker(ticker, concept)` handles non-December FYEs (NVDA/Jan, Nike/May, MSFT/June, AAPL/Sep, ...)
- Peer z-scores: `sec_gold.peer_zscore_by_sub_industry` — pre-computed cross-sectional z-scores per (concept, fiscal_year, gics_sub_industry), 174K rows
- Company snapshot: `sec_gold.company_snapshot(ticker)` returns every canonical metric at the most recent fiscal year

**Missing for serious research**:
- **Price / market cap data** — the biggest gap. yfinance doesn't scale. Needs Polygon.io or Tiingo.
- Factor library (value, quality, momentum, size) — requires prices
- QoQ/YoY/TTM derived metrics
- Incremental silver rebuild (currently full-rebuild, ~32 min)
- Form 13F / Form 4 data
- Python research SDK and parquet exports
- Long-tail XBRL tag coverage for the 10% of facts filed under company-extension namespaces

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

**Proposed schema**:
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
    FROM sec_gold.peer_zscore_by_sub_industry  -- already has canonical rollup
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

**Problem**: Some large banks (USB, TFC in S&P 500) don't file a single `Revenues`, `RevenuesNetOfInterestExpense`, or similar headline revenue tag. They file only decomposed components: `InterestIncomeExpenseNet` + `NoninterestIncome`. Today those banks are missing from `sec_gold.peer_zscore_by_sub_industry` for the revenue concept.

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

**Approach**: `dera export --matview peer_zscore_by_sub_industry --output s3://bucket/path` — dumps a gold matview to a partitioned parquet file using psycopg + pyarrow.

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
