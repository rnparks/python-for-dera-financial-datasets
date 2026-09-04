# Architecture

A bronze/silver/gold medallion pipeline in Postgres. Python is responsible for downloading SEC DERA zips and streaming them into bronze; SQL does every transformation after that.

## Layers at a glance

| Layer | Schema | Contents | Populated by |
|---|---|---|---|
| Bronze | `sec_raw` | `sub_raw`, `tag_raw`, `num_raw`, `pre_raw` — all `TEXT`, no constraints | `dera_pipeline.loader` via `COPY FROM STDIN` |
| Silver | `sec_silver` | `sub_silver`, `tag_silver`, `num_silver` — typed, deduplicated and **bitemporal**; `financials(mode)` function | `sql/02_silver/*.sql` |
| Gold | `sec_gold` | `fact_asof` (every vintage), `tradable_financials(_pit)`, `canonical_concepts` + `concept_tag_map` + `concept_formula`, `peer_stats`, `share_class_shares`, and the `as_of_*` accessor family | `sql/03_gold/*.sql` |
| Spine | `sec_reference` | `company`, `company_ticker`, `security`, `listing`, `eligibility`, `delisting_event`, `trading_calendar`, `share_class` | `sql/00_reference`, `05_spine`, `06_security` + `dera_pipeline.{reference,filings}` |

`sec_reference` sits deliberately **outside** the bronze→silver→gold chain.
`build-silver` opens with `DROP SCHEMA sec_silver CASCADE`, and the calendar,
company spine and security model must survive that — `sub_silver` resolves
`tradable_from` against the calendar during its own build.

See [`schema_overview.md`](schema_overview.md) for every table with row counts,
and [`data_sources.md`](data_sources.md) for what flows in.

## End-to-end flow

```
SEC DERA URLs
  └─ dera_pipeline.downloader (aiohttp + retry + semaphore)
       └─ data/raw/<year>q<n>/{sub,tag,num,pre}.txt
            └─ dera_pipeline.loader (psycopg3 COPY FROM STDIN, explicit col lists)
                 └─ sec_raw.{sub,tag,num,pre}_raw                    BRONZE
                      └─ sql/02_silver/020_sub_silver.sql            (cast types, PK)
                      └─ sql/02_silver/030_tag_silver.sql            (DISTINCT ON dedup)
                      └─ sql/02_silver/040_num_silver.sql            (CTE + window ranks + indexes)
                      └─ sql/02_silver/050_financials_function.sql   (single consolidated filter)
                           └─ sec_silver.num_silver                  SILVER
                                └─ sec_silver.financials('pit')
                                └─ sec_silver.financials('latest')
                                     └─ sql/03_gold/030_tradable_financials.sql
                                          └─ sec_gold.tradable_financials
                                          └─ sec_gold.tradable_financials_pit  GOLD
                                               └─ sec_gold.get_pit_financials(cik)
                                                    └─ sec_gold.get_financials_by_ticker(ticker)
```

## Why a Python bronze loader instead of a SQL procedure?

The legacy `sec_raw.load_sec_data()` plpgsql procedure used `COPY FROM PROGRAM` to shell out to `find | head | cut`:

- required `pg_read_server_files` / superuser privileges (won't run on managed Postgres like RDS or Supabase),
- parsed file headers with shell tools and trimmed trailing columns via `cut -f 1-N`,
- silently mis-aligned `num_raw` columns because the table DDL put `coreg` at position 4 while the actual SEC file puts it at position 8 — `cut` trimmed the 10-column file to 10 columns but positional COPY still wrote dates into `coreg` and CIKs into `ddate`.

The Python loader side-steps all of this:

1. It runs client-side, so no server-side file access is needed.
2. `cur.copy("COPY ... (col1, col2, ...) FROM STDIN")` uses an **explicit column list**, so file column order and table DDL order are decoupled — the `coreg` bug cannot recur.
3. On first load of each quarter it asserts the file header against `loader.EXPECTED_COLUMNS`, so any future SEC schema drift fails loud instead of corrupting silver.
4. A `sec_raw.load_log` table tracks loaded quarters so `load_all(incremental=True)` skips work already done.

## Silver: bitemporal, not merely dual-ranked

`num_silver` retains **every vintage of every fact**, with `known_at`,
`tradable_from`, `vintage_seq`, `superseded_known_at`, `superseded_tradable` and
`is_original_disclosure`. "What did we believe on date T" is a half-open interval
scan returning exactly one row per fact key, with no window function at query
time:

```sql
WHERE tradable_from <= T
  AND (superseded_tradable > T OR superseded_tradable IS NULL)
```

`tradable_from` is derived from the EDGAR acceptance timestamp against a real
NYSE calendar, so it answers *when could I have acted on this*, which is not the
same question as *when was it filed*. 48% of filings are accepted after the close
and stamped that same `filed_date`.

The older dual ranking is still carried for compatibility:

```sql
ROW_NUMBER() OVER (
    PARTITION BY cik, tag, value_date, qtrs, uom, coreg, segments
    ORDER BY filed_date ASC, adsh ASC
) AS rank_pit,

ROW_NUMBER() OVER (
    PARTITION BY cik, tag, value_date, qtrs, uom, coreg, segments
    ORDER BY filed_date DESC, adsh DESC
) AS rank_latest
```

- `rank_pit = 1` is the **first time we ever saw this value** — no look-ahead, correct for backtesting.
- `rank_latest = 1` is the **most recently restated value** — correct for fundamental analysis of historical results.

Both ranks live in the same table; `sec_silver.financials(p_mode)` exposes them:

```sql
SELECT * FROM sec_silver.financials('pit')    WHERE cik = 320193;
SELECT * FROM sec_silver.financials('latest') WHERE cik = 320193;
```

The consolidated-only filter (`segments IS NULL AND coreg IS NULL`) lives inside this function and nowhere else, so adding a new gold consumer doesn't risk double-filtering or forgetting the filter.

## The security spine

`company_ticker` maps a CIK to a ticker and has no notion of an instrument that
begins and ends. `sec_reference.security` is the tradable thing, carrying
`first_trade_date` (with a `first_trade_basis` recording the evidence class) and
`delisting_date`. Both are derived from EDGAR filing events — 8-A registrations
and Form 25 notices — because filings are immutable and dated, while any
current-state file has already deleted the companies that failed.

Neither date comes from the presence of a form alone. JPMorgan has filed 46 Form
25s and has never been delisted; Apple's earliest 8-A in EDGAR is from 2014 and
it listed in 1980. Both rules are behavioural and both are documented in
`sql/06_security/010_security_populate.sql`.

Two invariants are enforced by CHECK constraint rather than convention: no
eligibility interval may begin before `first_trade_date`, or outlive
`delisting_date`.

## Gold: two sibling matviews

`sec_gold.tradable_financials` and `sec_gold.tradable_financials_pit` are parallel materialized views joining the S&P 1500 universe to the two silver ranks. Backtesting reads the `_pit` matview; dashboards and fundamental screens read the latest one. Each has four indexes (ticker, value_date, tag, cik). Refresh both with:

```bash
uv run dera build-gold            # REFRESH included
uv run dera build-gold --no-refresh   # skip the refresh
```

or manually:

```sql
REFRESH MATERIALIZED VIEW sec_gold.tradable_financials;
REFRESH MATERIALIZED VIEW sec_gold.tradable_financials_pit;
```

## Metric aliases

The legacy `get_pit_financials` baked a hardcoded `CASE` expression into the function body to remap `Revenues` and `RevenueFromContractWithCustomerExcludingAssessedTax` both to "Total Revenue". That mapping now lives in `sec_gold.metric_aliases(tag TEXT PRIMARY KEY, display_name TEXT)`. Add a new display name with a single `INSERT`; no `ALTER FUNCTION` needed.

## Reference data

`sec_silver.universe_sp1500` and `sec_silver.ticker_map` are loaded by `dera_pipeline.reference` from `data/reference/sp1500_universe.csv` and `data/reference/tickers.csv`. The legacy `\copy` statements required psql, which psycopg can't run; the Python path also handles the dedup and `.`→`-` normalization that the old SQL did server-side.

Regenerate the S&P universe from Wikipedia:

```bash
uv run python tools/fetch_sp1500.py
```

Replace `data/reference/tickers.csv` manually when SEC publishes a new CIK crosswalk.
