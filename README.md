# DERA Pipeline

A Postgres research platform for SEC's [DERA Financial Statement Data Sets](https://www.sec.gov/dera/data/financial-statement-data-sets),
built for **point-in-time correct** equity research.

Downloads SEC's quarterly XBRL dumps into a `sec_raw` bronze layer, types and
deduplicates them into a bitemporal `sec_silver`, and exposes a `sec_gold` query
layer with a canonical concept taxonomy and peer statistics. A separate
`sec_reference` spine tracks companies, securities and historical universes
without survivorship bias.

**Two things make this different from a plain XBRL loader:**

1. **Availability, not filing date.** Every fact records when it became
   *actionable* — the EDGAR acceptance timestamp resolved against a real NYSE
   calendar. **57%** of filings (247,216 of 433,717) are accepted after the close and
   stamped that same `filed_date`; **210,683** of them roll to a later session.
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
```

## Setup

Requires Python ≥ 3.11 and Postgres ≥ 14. Install [uv](https://docs.astral.sh/uv/) if you don't have it.

```bash
uv sync
cp .env.example .env      # then set SEC_USER_AGENT and PG_DSN
```

| Variable | Purpose |
|---|---|
| `SEC_USER_AGENT` | SEC rate-limits generic agents — use a descriptive string with a contact email, e.g. `"Jane Doe <jane@example.com>"`. |
| `PG_DSN` | Postgres connection string, e.g. `postgresql://user:pass@localhost:5432/dera`. |

Expect roughly **141 GB** of Postgres and **31 GB** on disk for a full build.

**Figures throughout this file are as of 2026-09-04.**

## Quickstart

```bash
uv run dera run-all        # download + load + silver + gold
uv run dera verify         # 28 correctness checks; non-zero exit on failure
```

Or one stage at a time:

```bash
uv run dera download --from 2009q1 --to 2026q2   # ~29 GB on disk
uv run dera init-db                               # bronze DDL
uv run dera load                                  # COPY → bronze (incremental)
uv run dera build-silver                          # ~39 min
uv run dera build-gold                            # ~16 min
```

The security lifecycle model is a separate, additive path:

```bash
uv run dera fetch-filing-index      # EDGAR bulk archive, ~1.5 GB
uv run dera build-security-model    # securities, listings, delistings, universes
```

`run-all` will **not** destroy a populated bronze — that needs an explicit
`--reinit-bronze`.

## Querying

```sql
-- What a company reported, as now understood
SELECT * FROM sec_gold.company_snapshot('AAPL');

-- One concept, fiscal-year aware
SELECT * FROM sec_gold.latest_annual_by_ticker('NKE', 'revenue');

-- BACKTESTING: what was knowable on a date. No default knowledge date,
-- deliberately — omitting it is an error rather than a silent look-ahead.
SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2015-06-30');

-- Who was actually investable then, delisted companies included
SELECT * FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30');
```

That last query returns 7,418 members, of which **1,925 (26%) have since
delisted**. A universe built from today's index membership returns none of them.

## Reference data

Tracked CSVs under `data/reference/`, all regenerable — see
[`docs/data_sources.md`](docs/data_sources.md) for provenance and known gaps.

```bash
uv run python tools/fetch_sp1500.py           # S&P 1500 membership (Wikipedia)
uv run python tools/fetch_ticker_history.py   # CIK↔ticker via Wayback; resumes
uv run python tools/build_calendar.py         # NYSE trading calendar
```

## Repository layout

```
dera_pipeline/       # the Python package
├── cli.py          # argparse entry point (`uv run dera ...`)
├── config.py       # env-driven constants
├── db.py           # thin psycopg3 wrapper
├── downloader.py   # async retry+semaphore fetcher
├── filings.py      # EDGAR bulk submissions → security lifecycle events
├── loader.py       # bronze COPY-from-STDIN loader
└── reference.py    # CSV → reference table loader

sql/                 # executed in lexical order by directory
├── 00_reference/   # trading calendar, ticker history, share class, security DDL
├── 01_bronze/      # sec_raw schema + raw tables
├── 02_silver/      # typed bitemporal tables + financials() function
├── 03_gold/        # matviews, canonical concepts, as-of accessors
├── 04_reference/   # universe_sp1500, ticker_map
├── 05_spine/       # company spine (needs 04 to be loaded first)
└── 06_security/    # security model (needs the filing index loaded first)

data/
├── raw/            # DERA quarterly dumps      (gitignored, 29 GB)
├── edgar/          # EDGAR submissions archive (gitignored, 1.5 GB)
└── reference/      # tracked reference CSVs

docs/                # architecture, schema, data sources, SEC references
tools/               # standalone utilities and verify_pit.sql
notebooks/
├── sec_examples/   # original SEC DERA tutorials (upstream)
└── scratch/        # one-off analysis
```

The numeric prefixes on `sql/` directories are load-bearing: `05_spine` and
`06_security` exist because both read data that a Python loader populates
mid-build, and `run_sql_dir` executes an entire directory before any Python runs.

## License

CC0 1.0 Universal. Forked from the SEC's public [DERA examples repository](https://www.sec.gov/dera/data/financial-statement-data-sets).
