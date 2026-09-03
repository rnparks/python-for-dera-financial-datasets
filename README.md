# DERA Pipeline

A Postgres medallion pipeline for SEC's [DERA Financial Statement Data Sets](https://www.sec.gov/dera/data/financial-statement-data-sets).

Downloads SEC's quarterly XBRL dumps, lands them into a `sec_raw` bronze layer, cleans and types them into `sec_silver`, and joins them against the S&P 1500 universe for a `sec_gold.tradable_financials` materialized view that powers ticker-keyed lookups.

## Pipeline stages

```
SEC DERA zip URLs
  └─[dera download]─→ data/raw/<year>q<n>/{sub,tag,num,pre}.txt
  └─[dera init-db]──→ sec_raw schema + 4 empty bronze tables
  └─[dera load]─────→ sec_raw.{sub,tag,num,pre}_raw                (BRONZE)
  └─[dera build-silver]─→ sec_silver.{sub,tag,num}_silver
                         + sec_silver.financials(mode) function
                         + sec_silver.universe_sp1500, ticker_map  (SILVER)
  └─[dera build-gold]───→ sec_gold.tradable_financials (latest)
                         + sec_gold.tradable_financials_pit
                         + sec_gold.get_pit_financials(cik)
                         + sec_gold.get_financials_by_ticker(tkr)  (GOLD)
```

See [`docs/architecture.md`](docs/architecture.md) for the layer-by-layer breakdown.

## Setup

Requires Python ≥ 3.11 and Postgres ≥ 14. Install [uv](https://docs.astral.sh/uv/) if you don't have it.

```bash
# Install deps into a managed venv
uv sync

# Copy the env template and fill in your credentials
cp .env.example .env
# Edit .env to set SEC_USER_AGENT and PG_DSN
```

The pipeline requires two environment variables:

| Variable | Purpose |
|---|---|
| `SEC_USER_AGENT` | SEC rate-limits generic user agents — provide a descriptive string with a contact email, e.g. `"Jane Doe <jane@example.com>"`. |
| `PG_DSN` | Postgres connection string, e.g. `postgresql://user:pass@localhost:5432/dera`. |

## Quickstart

Full rebuild against a fresh database:

```bash
uv run dera run-all
```

Or run one stage at a time:

```bash
uv run dera download --from 2009q1 --to 2026q2    # ~13 GB on disk
uv run dera init-db                                # bronze DDL
uv run dera load                                   # COPY .txt → bronze (incremental by default)
uv run dera build-silver                           # silver tables + reference data
uv run dera build-gold                             # gold matviews + helper functions
```

Common variations:

```bash
uv run dera download --from 2026q2 --to 2026q2     # just the latest quarter
uv run dera load --quarter 2026q2                  # load a specific quarter
uv run dera load --full                            # re-load everything (ignore load_log)
uv run dera load --truncate                        # wipe bronze first
uv run dera build-gold --no-refresh                # rebuild DDL but skip REFRESH
```

Once gold is built, query by ticker:

```sql
SELECT * FROM sec_gold.get_financials_by_ticker('AAPL');
SELECT * FROM sec_gold.tradable_financials WHERE ticker = 'MSFT' ORDER BY value_date DESC LIMIT 20;
```

## Reference data

Two CSVs live under `data/reference/` and are loaded into `sec_silver` during `build-silver`:

- **`sp1500_universe.csv`** — S&P 500 + 400 + 600 constituent list. Regenerate from Wikipedia via `uv run python tools/fetch_sp1500.py`.
- **`tickers.csv`** — CIK ↔ ticker crosswalk (CIK, ticker, name, exchange). Replace manually when the SEC crosswalk updates.

## Repository layout

```
dera_pipeline/        # the Python package — download, load, DB wiring, CLI
├── cli.py           # argparse entry point (`uv run dera ...`)
├── config.py        # env-driven constants and validated accessors
├── db.py            # thin psycopg3 wrapper
├── downloader.py    # async retry+semaphore fetcher
├── loader.py        # bronze COPY-from-STDIN loader
└── reference.py     # CSV → sec_silver reference loader

sql/
├── 01_bronze/       # sec_raw schema + 4 raw tables
├── 02_silver/       # sec_silver schema, typed tables, financials() function
├── 03_gold/         # sec_gold schema, tradable_financials matviews, helpers
└── 04_reference/    # universe_sp1500, ticker_map table DDL

data/
├── raw/             # DERA quarterly dumps (gitignored — fetch with `dera download`)
└── reference/       # tracked reference CSVs and xlsx

docs/                # SEC schema references, architecture notes
notebooks/
├── sec_examples/    # original SEC DERA Jupyter tutorials (upstream)
└── scratch/         # one-off analysis scripts

tools/               # standalone utilities (e.g. fetch_sp1500.py)
```

## License

CC0 1.0 Universal. Forked from the SEC's public [DERA examples repository](https://www.sec.gov/dera/data/financial-statement-data-sets).
