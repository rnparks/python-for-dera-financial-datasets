# DERA Pipeline

A Postgres research platform for SEC's [DERA Financial Statement Data Sets](https://www.sec.gov/dera/data/financial-statement-data-sets),
built for **point-in-time correct** equity research.

Downloads SEC's quarterly XBRL dumps into a `sec_raw` bronze layer, types and
deduplicates them into a bitemporal `sec_silver`, and exposes a `sec_gold` query
layer with a canonical concept taxonomy (tag priorities ordered by the FASB
US-GAAP calculation linkbase where it speaks, e.g. gross profit) and peer
statistics. A separate
`sec_reference` spine tracks companies, securities and historical universes
without survivorship bias.

**Two things make this different from a plain XBRL loader:**

1. **Availability, not filing date.** Every fact records when it became
   *actionable* — the EDGAR acceptance timestamp resolved against a real NYSE
   calendar. **57%** of filings (247,216 of 433,717) are accepted after the close;
   **48%** of all filings still carry that day's `filed_date` and would look a
   session early to anything keyed on it.
2. **Every vintage is kept.** A restatement does not overwrite history. GE's
   fiscal 2022 revenue exists as four vintages across three values — $76.555B as
   first filed, $58.100B after an 8-K, $29.139B after a 2025 restatement — and
   you can ask what any of them looked like on any date.

## Documentation

| Read this | For |
|---|---|
| [`docs/data_sources.md`](docs/data_sources.md) | What is downloaded, from where, and how far it can be traced |
| [`docs/schema_overview.md`](docs/schema_overview.md) | Every table and view, and which one to use |
| [`docs/gold_tables.md`](docs/gold_tables.md) | Deep reference for `sec_gold`, all function signatures |
| [`docs/architecture.md`](docs/architecture.md) | Layer-by-layer design and the reasoning behind it |
| [`features.md`](features.md) | Current status and roadmap |

## Pipeline stages

```
SEC DERA quarterly zips
  └─[dera download]──────────→ data/raw/<year>q<n>/{sub,tag,num,pre}.txt
  └─[dera init-db]───────────→ sec_raw schema + bronze tables
  └─[dera load]──────────────→ sec_raw.{sub,tag,num,pre}_raw          BRONZE
  └─[dera build-silver]──────→ sec_silver.{sub,tag,num}_silver        SILVER
                               + bitemporal availability columns
                               + sec_reference spine and calendar
  └─[dera build-gold]────────→ sec_gold.fact_asof                     GOLD
                               + tradable_financials(_pit)
                               + canonical concepts, peer_stats

EDGAR bulk submissions archive
  └─[dera fetch-filing-index]──→ data/edgar/submissions.zip
  └─[dera build-security-model]→ sec_reference.{security,listing,      SPINE
                                 eligibility,delisting_event}

Internet Archive captures of SEC's ticker file; Wikipedia page history
  └─[tools/fetch_ticker_history.py]→ data/reference/ticker_history.csv.gz
  └─[tools/fetch_sp500_history.py]─→ data/reference/sp500_history.csv.gz
  └─[dera rebuild-reference]───────→ reference CSVs → spine (refilled in place)
                                     → security model → gold matviews whose
                                       inputs changed
```

## Setup

Requires Python ≥ 3.11 and Postgres ≥ 14 with the `btree_gist` contrib extension (the spine creates it; it enforces that the membership timeline never overlaps). The `pgstattuple` contrib extension is optional and nothing in the pipeline uses it: `pgstattuple_approx` measures the free space a quarterly fold leaves in the big heaps (`docs/schema_overview.md`, the sizes). Install [uv](https://docs.astral.sh/uv/) if you don't have it.

```bash
uv sync
cp .env.example .env      # then set SEC_USER_AGENT and PG_DSN
```

| Variable | Purpose |
|---|---|
| `SEC_USER_AGENT` | SEC rate-limits generic agents — use a descriptive string with a contact email, e.g. `"Jane Doe <jane@example.com>"`. |
| `PG_DSN` | Postgres connection string, e.g. `postgresql://user:pass@localhost:5432/dera`. |

Expect roughly **140 GB** of Postgres and **31 GB** on disk for a full build.

**Figures throughout this file are as of 2026-09-04.**

## Quickstart

```bash
uv run dera run-all        # download + load + silver + gold
uv run dera verify         # 73 data-correctness checks; non-zero exit on failure
uv run pytest              # unit tests for the pure Python (no database)
```

Or one stage at a time:

```bash
uv run dera download --from 2009q1 --to 2026q3   # ~30 GB on disk; default --to is the last full quarter
uv run dera init-db                               # bronze DDL
uv run dera load                                  # COPY → bronze (incremental; every row carries its source_quarter)
uv run dera build-silver                          # ~39 min
uv run dera build-gold                            # ~26 min, 20 of them fact_asof (22 GB plus 10 GB of indexes)
```

Each new DERA quarter after that (four a year) is a fold, not a rebuild:

```bash
uv run dera download --from 2026q3 --to 2026q3
uv run dera load --quarter 2026q3            # --force replaces a quarter already loaded
uv run dera build-silver --quarter 2026q3    # recomputes only the fact partitions the quarter touches (~18 min; the full build is 39), then refreshes suspect_fact (~20 min)
uv run dera rebuild-reference                # spine, security model, then the gold matviews whose inputs changed (a new quarter changes them all: ~27 min)
uv run dera verify                           # the correctness suite
```

Prices and the backtest (`sec_market`, a vendor, not SEC data; see `docs/data_sources.md` section 8):

```bash
uv run dera load-prices                      # month-end closes for the primary ticker of every company ever in the S&P 1500 (Yahoo, ~10 min)
uv run dera build-factor-panel --index SP500 # the factor sheet at every month end since 2010, stored for the backtest (~100 s per date)
uv run dera build-factor-panel --index SP400 --since 2011-01-01   # the 400 and 600 from where their replayed histories begin
uv run dera build-factor-panel --index SP600 --since 2018-08-01
uv run dera build-factor-panel --index SP1500 --since 2018-08-01  # the three re-ranked together, one row per company; seconds per date
```

Rehearsed end to end on 2026-09-10 by reloading 2026q2 under `--force`: 52
minutes, every silver, reference and gold row count identical afterwards, and
the suite green. `docs/data_sources.md` has the stage timings.

The security lifecycle model is a separate, additive path:

```bash
uv run dera fetch-filing-index      # EDGAR bulk archive, ~1.5 GB
uv run dera build-security-model    # securities, listings, delistings, universes
```

and a reference refresh ends with a rebuild of everything that joins to it:

```bash
uv run python tools/fetch_ticker_history.py --batch 0   # monthly archive captures + live file
uv run dera rebuild-reference    # CSVs → spine (in place) → security model → refresh what changed
```

The spine is refilled in place, so the gold matviews survive and only the ones
that read what changed are refreshed: a crosswalk change refreshes four of the
five and leaves the 33 GB `fact_asof` alone (about 6 minutes end to end, against
a 32-minute gold rebuild before), a share-class mapping change refreshes one,
and when nothing changed nothing is refreshed (52 seconds). `--recreate-spine`
drops the spine tables first, which a column change needs; gold goes with them
and is rebuilt in full.

`run-all` will **not** destroy a populated bronze — that needs an explicit
`--reinit-bronze`. `build-silver` without the filing index leaves the existing
security model in place rather than emptying it.

## Querying

```sql
-- What a company reported, as now understood
SELECT * FROM sec_gold.company_snapshot('AAPL');

-- One concept, fiscal-year aware
SELECT * FROM sec_gold.latest_annual_by_ticker('NKE', 'revenue');

-- BACKTESTING: what was knowable on a date. No default knowledge date,
-- deliberately — omitting it is an error rather than a silent look-ahead.
SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2022-06-30');

-- Ticker resolution is dated. Observed crosswalk intervals start in
-- 2018-12; a company that has only ever had one ticker is extended back
-- to its first filing, flagged as inferred, so this resolves ...
SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2015-06-30');

-- ... while a ticker that changed (Meta was FB in 2015) raises rather
-- than returning fifteen empty rows. Key on the CIK there.
SELECT * FROM sec_gold.as_of_snapshot(1326801, DATE '2015-06-30');

-- Quarterly flows and trailing twelve months, computed on demand from the
-- same vintages: Apple's quarter to 2024-06-30 as it was knowable on
-- 2024-08-15, with quarter-over-quarter, year-over-year and trailing growth.
SELECT concept, quarter_end, q_value, qoq_growth, yoy_growth, ttm_value, ttm_growth
FROM sec_gold.as_of_trailing('AAPL', DATE '2024-08-15');

-- An accounting factor sort as it was knowable on a date: gross profit over
-- total assets (Novy-Marx 2013), S&P 500 constituents of 2024-11-15
SELECT ticker, value_date, days_stale, value AS gross_profit_to_assets
FROM sec_gold.peer_stats_asof('SP500', DATE '2024-11-15')
WHERE concept = 'gross_profit_to_assets' AND peer_level = 'sector'
ORDER BY value DESC LIMIT 10;

-- Standardized unexpected earnings (Foster, Olsen and Shevlin 1984): the
-- newest quarter of every constituent, ranked; computed on demand
SELECT ticker, quarter_end, sue, sue_rank, sue_percentile
FROM sec_gold.surprise_asof('SP500', DATE '2024-07-15')
WHERE sue IS NOT NULL ORDER BY sue_rank LIMIT 10;

-- Quarterly return on assets and on equity (JKP niq_at, niq_be): the newest
-- quarter of every constituent over the balance at the end of the prior
-- quarter, ranked; computed on demand
SELECT ticker, quarter_end, roa_q, roa_rank, roe_q, roe_rank
FROM sec_gold.profitability_asof('SP500', DATE '2024-07-15')
WHERE roa_q IS NOT NULL ORDER BY roa_rank LIMIT 10;

-- The factor sheet: every factor per constituent as a value, an index
-- percentile and a sector percentile, signed so higher is better, with
-- an equal-weight composite; all as knowable on the date
SELECT ticker, gics_sector, n_factors, composite, gp_at_pct, ocf_at_pct, roe_q_pct, sue_pct
FROM sec_gold.factor_sheet_asof('SP500', DATE '2024-07-15')
ORDER BY composite DESC NULLS LAST LIMIT 10;

-- Does it pay? Sort the stored panel into quintiles on a factor at every
-- quarter end, hold equal-weighted to the next, and summarise: per bucket,
-- the top-minus-bottom spread and the equal-weight benchmark
SELECT * FROM sec_market.backtest_summary('SP500', 'ocf_at', 'quarterly', DATE '2010-01-01', NULL, 5);

-- Apple's market cap as knowable on a date: the as-traded month-end close
-- before it times the cover-page shares knowable on it
SELECT * FROM sec_market.market_cap_at(320193, DATE '2024-11-15');

-- Who was actually investable then, delisted companies included
SELECT * FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30');

-- The same, entering a company only once its equity was priced: the
-- strict reading of "first trade" for issuers that reported before they
-- listed (216 fewer members in 2015, 31 fewer in 2024)
SELECT * FROM sec_reference.universe_at('filers_10k_15m_strict', DATE '2015-06-30');

-- Scale-free peer scores without a price in sight: net margin against
-- sector peers by fiscal year, with percentile and z-score
SELECT fiscal_year, value AS net_margin, peer_percentile, zscore, peer_count
FROM sec_gold.peer_stats
WHERE ticker = 'NVDA' AND concept = 'net_margin' AND peer_level = 'sector'
ORDER BY fiscal_year;

-- The same cross-section as it was KNOWABLE on a date: constituents of
-- the day, each company's latest annual figures actionable by then,
-- peer moments over only those. A function, computed on demand.
SELECT ticker, value_date, days_stale, value AS net_margin, peer_percentile
FROM sec_gold.peer_stats_asof('SP500', DATE '2020-06-30')
WHERE concept = 'net_margin' AND peer_level = 'sector'
ORDER BY peer_percentile DESC LIMIT 10;

-- Who was in the S&P 500 then, with the GICS classification of the time
SELECT * FROM sec_reference.index_members('SP500', DATE '2015-06-30');
```

The filers query returns 7,298 members, of which **3,012 (41%) have since
delisted or deregistered**. A universe built from today's index membership
returns none of them. The S&P 500 query comes from Wikipedia's page history
replayed monthly since 2008: SVB Financial is a member from 2018-03-19 to
2023-03-24, Tesla from 2020-12-21, and 841 companies have been in the index
against 503 on today's page. The S&P 400 (since 2011) and S&P 600 (since 2018)
are replayed the same way, so a mid-cap or small-cap cross-section is the index
of its day too.

## Compustat-style items

`dera_pipeline/compustat.py` turns XBRL facts into Compustat items (AT, CEQ, DLC,
XSGA, ...) by a cited map, for replicating published predictors; see
[`docs/compustat_items.md`](docs/compustat_items.md).

```bash
uv run python tools/export_compustat.py    # data/exports/compustat/annual.parquet, point in time
uv run python tools/audit_compustat_items.py   # S&P balancing identities -> docs/audits/compustat_items.md
uv run python tools/export_compustat_quarterly.py   # data/exports/compustat/quarterly.parquet
uv run python tools/fetch_notes_datasets.py   # SEC Financial Statement and Notes archives -> data/raw_notes/ (27.6 GB)
uv run python tools/extract_notes_facts.py    # pension, segment, customer footnote facts -> data/exports/notes/
uv run python tools/export_notes_items.py     # pensions, segments, customers .parquet in data/exports/compustat/
```

Footnote items (pension plans, segments, major customers) are not in `sec_data`,
which loads the primary statements only; they come from the Notes data sets
(`docs/data_sources.md`, source 7).

## Reference data

Tracked files under `data/reference/`, all regenerable — see
[`docs/data_sources.md`](docs/data_sources.md) for provenance and known gaps.
One is kept by hand: `data/reference/index_cik_overrides.csv`, the constituent
runs no rule resolves, each row citing its evidence.

```bash
uv run python tools/fetch_sp1500.py                     # today's S&P 1500 (Wikipedia)
uv run python tools/fetch_sp500_history.py --batch 0    # S&P 500 membership, monthly since 2008; resumes
uv run python tools/fetch_ticker_history.py --batch 0   # CIK↔ticker via the Internet Archive; resumes
uv run python tools/fetch_cover_page_classes.py --sp500 # share-class mappings from 10-K cover pages
uv run python tools/build_calendar.py                   # NYSE trading calendar, two years ahead
uv run python tools/fetch_usgaap_cost_elements.py       # FASB taxonomy: cost-of-revenue element years and calc tree
uv run python tools/fetch_usgaap_element_docs.py        # FASB taxonomy: definitions and calc context of elements
uv run python tools/ff_baseline.py SP500 --download     # factor spreads vs Fama-French 5 factors and momentum (data/external/french)
uv run python tools/factor_report.py SP500              # the backtest report as one HTML file -> docs/reports/
uv run python tools/factor_report.py --overview         # the four universes side by side, after the four per-index runs
uv run python tools/score_methods.py                   # AQR, MSCI and Barra scoring, strict sector-neutral, equal- and cap-weighted -> docs/reports/ (market caps cached in data/external/french)
```

## Keeping the documentation current

The docs in this repository are treated as part of the code, because they have
gone badly stale before — far enough that `README.md` once described a pipeline
that stopped three layers short of what existed.

Two habits keep that from recurring:

1. **Update docs in the same commit as the change.** `CLAUDE.md` carries a table
   mapping what you changed to what needs updating.
2. **Run the checker.** `uv run dera verify-docs` validates every database object
   name (in prose and inside SQL examples), file path, CLI command and
   cross-document link in the Markdown against the live repository and
   database. It exits non-zero on failure.

The checker deliberately does not validate prose or figures — a check that is
wrong often enough to ignore is worse than none. Figures are date-stamped
instead, so you can see their vintage.

Optionally enforce it locally with the tracked hook:

```bash
ln -sf ../../tools/hooks/pre-commit .git/hooks/pre-commit
```

It blocks any commit whose docs reference a database object, file, command or
link that does not exist, and prints `file:line` for each. `git commit
--no-verify` bypasses it. If Postgres is unreachable the hook warns and allows
the commit rather than blocking — a database being down is not a documentation
problem, and a hook that fires on the wrong thing trains you to bypass it.

`.git/hooks` is not tracked, so each clone installs its own; this is a local
convenience, not a guarantee about the repository. GitHub Actions runs `ruff`
and `pytest` on every push; the database-backed suites stay local.

## Repository layout

```
dera_pipeline/       # the Python package
├── cli.py          # argparse entry point (`uv run dera ...`)
├── config.py       # env-driven constants
├── db.py           # thin psycopg3 wrapper
├── downloader.py   # async retry+semaphore fetcher
├── filings.py      # EDGAR bulk submissions → security lifecycle events
├── loader.py       # bronze COPY-from-STDIN loader
├── prices.py       # Yahoo month-end prices and the factor panel (sec_market)
└── reference.py    # CSV → reference table loader

sql/                 # executed in lexical order by directory
├── 00_reference/   # trading calendar, ticker history, share class, security DDL
├── 01_bronze/      # sec_raw schema + raw tables
├── 02_silver/      # typed bitemporal tables + financials() function
├── 03_gold/        # matviews, canonical concepts, as-of accessors
├── 04_reference/   # universe_sp1500, ticker_map
├── 05_spine/       # company spine and dated crosswalk (needs 04 to be loaded first)
├── 06_security/    # security model (needs the filing index loaded first)
└── 07_market/      # sec_market: month-end prices, the factor panel, the backtest (run by load-prices / build-factor-panel)

data/
├── raw/            # DERA quarterly dumps      (gitignored, 29 GB)
├── edgar/          # EDGAR submissions archive (gitignored, 1.5 GB)
└── reference/      # tracked reference files (the crosswalk is gzipped)

tests/               # pytest, pure functions only
docs/                # architecture, schema, data sources, SEC references
├── audits/         # generated audit tables
└── reports/        # generated reports: factor_backtest_<index>_<date>.html for SP500, SP400, SP600 and SP1500 (2026-10-13)
tools/               # standalone utilities, verify_pit.sql, the pre-commit hook
notebooks/
├── sec_examples/   # original SEC DERA tutorials (upstream)
└── scratch/        # one-off analysis
```

The numeric prefixes on `sql/` directories are load-bearing: `05_spine` and
`06_security` exist because both read data that a Python loader populates
mid-build, and `run_sql_dir` executes an entire directory before any Python runs.

## License

CC0 1.0 Universal. Forked from the SEC's public [DERA examples repository](https://www.sec.gov/dera/data/financial-statement-data-sets).
