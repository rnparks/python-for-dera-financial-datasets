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

Requires Python ≥ 3.11 and Postgres ≥ 14 with the `btree_gist` contrib extension (the spine creates it; it enforces that the membership timeline never overlaps). Install [uv](https://docs.astral.sh/uv/) if you don't have it.

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
uv run dera verify         # 52 data-correctness checks; non-zero exit on failure
uv run pytest              # unit tests for the pure Python (no database)
```

Or one stage at a time:

```bash
uv run dera download --from 2009q1 --to 2026q2   # ~29 GB on disk; default --to is the last full quarter
uv run dera init-db                               # bronze DDL
uv run dera load                                  # COPY → bronze (incremental; refuses a quarter twice)
uv run dera build-silver                          # ~39 min
uv run dera build-gold                            # ~26 min, 20 of them fact_asof (22 GB plus 10 GB of indexes)
```

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

-- Who was actually investable then, delisted companies included
SELECT * FROM sec_reference.universe_at('filers_10k_15m', DATE '2015-06-30');

-- Who was in the S&P 500 then, with the GICS classification of the time
SELECT * FROM sec_reference.index_members('SP500', DATE '2015-06-30');
```

The filers query returns 7,298 members, of which **3,012 (41%) have since
delisted or deregistered**. A universe built from today's index membership
returns none of them. The S&P 500 query comes from Wikipedia's page history
replayed monthly since 2008: SVB Financial is a member from 2018-03-19 to
2023-03-24, Tesla from 2020-12-21, and 840 companies have been in the index
against 503 on today's page.

## Reference data

Tracked files under `data/reference/`, all regenerable — see
[`docs/data_sources.md`](docs/data_sources.md) for provenance and known gaps.

```bash
uv run python tools/fetch_sp1500.py                     # today's S&P 1500 (Wikipedia)
uv run python tools/fetch_sp500_history.py --batch 0    # S&P 500 membership, monthly since 2008; resumes
uv run python tools/fetch_ticker_history.py --batch 0   # CIK↔ticker via the Internet Archive; resumes
uv run python tools/fetch_cover_page_classes.py --sp500 # share-class mappings from 10-K cover pages
uv run python tools/build_calendar.py                   # NYSE trading calendar, two years ahead
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
└── reference.py    # CSV → reference table loader

sql/                 # executed in lexical order by directory
├── 00_reference/   # trading calendar, ticker history, share class, security DDL
├── 01_bronze/      # sec_raw schema + raw tables
├── 02_silver/      # typed bitemporal tables + financials() function
├── 03_gold/        # matviews, canonical concepts, as-of accessors
├── 04_reference/   # universe_sp1500, ticker_map
├── 05_spine/       # company spine and dated crosswalk (needs 04 to be loaded first)
└── 06_security/    # security model (needs the filing index loaded first)

data/
├── raw/            # DERA quarterly dumps      (gitignored, 29 GB)
├── edgar/          # EDGAR submissions archive (gitignored, 1.5 GB)
└── reference/      # tracked reference files (the crosswalk is gzipped)

tests/               # pytest, pure functions only
docs/                # architecture, schema, data sources, SEC references
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
