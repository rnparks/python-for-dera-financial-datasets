"""Reference-data loader for `sec_silver.universe_sp1500` and
`sec_silver.ticker_map`.

The legacy SQL used psql's `\\copy` meta-command, which cannot run over
psycopg. This module reads the two reference CSVs directly and streams
them into the silver reference tables via psycopg's copy API. The
normalization the old SQL did in-database (dedup + dot-to-hyphen for
class-share tickers like `BRK.B` → `BRK-B`) happens here in Python.
"""

from __future__ import annotations

import csv
from pathlib import Path

import psycopg

from . import config


def load_sp1500_universe(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/sp1500_universe.csv → sec_silver.universe_sp1500.
    Returns the number of unique tickers inserted.
    """
    seen: dict[str, tuple[str, str, str]] = {}
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ticker = row["ticker"].replace(".", "-")
            if ticker not in seen:
                seen[ticker] = (ticker, row["name"], row["index_name"])

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_silver.universe_sp1500")
        with cur.copy(
            "COPY sec_silver.universe_sp1500 (ticker, name, index_name) "
            "FROM STDIN WITH (FORMAT CSV, DELIMITER E'\\t')"
        ) as cp:
            for ticker, name, index_name in seen.values():
                cp.write_row((ticker, name, index_name))
    return len(seen)


def load_ticker_map(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/tickers.csv → sec_silver.ticker_map.

    The CSV has no header; columns are ``cik, ticker, name, exchange``.
    One ticker may map to multiple CIKs in the SEC source; we keep the
    first occurrence to match the legacy ``ON CONFLICT DO NOTHING``
    behaviour.
    """
    seen: dict[str, tuple[int, str, str, str]] = {}
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        for row in reader:
            if len(row) < 4:
                continue
            cik_str, ticker, name, exchange = row[0], row[1], row[2], row[3]
            try:
                cik = int(cik_str)
            except ValueError:
                continue
            ticker = ticker.strip().upper()
            if not ticker or ticker in seen:
                continue
            seen[ticker] = (cik, ticker, name, exchange)

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_silver.ticker_map")
        with cur.copy(
            "COPY sec_silver.ticker_map (cik, ticker, name, exchange) "
            "FROM STDIN WITH (FORMAT CSV, DELIMITER E'\\t')"
        ) as cp:
            for cik, ticker, name, exchange in seen.values():
                cp.write_row((cik, ticker, name, exchange))
    return len(seen)


def load_all_reference(conn: psycopg.Connection) -> dict[str, int]:
    """Load every reference table. Called by `dera build-silver`."""
    sp1500 = config.REFERENCE_DIR / "sp1500_universe.csv"
    tickers = config.REFERENCE_DIR / "tickers.csv"
    if not sp1500.exists():
        raise FileNotFoundError(
            f"{sp1500} missing — generate with `uv run python tools/fetch_sp1500.py`"
        )
    if not tickers.exists():
        raise FileNotFoundError(
            f"{tickers} missing — place the SEC ticker→CIK crosswalk CSV here"
        )

    result: dict[str, int] = {}
    result["sp1500"] = load_sp1500_universe(conn, sp1500)
    print(f"  universe_sp1500 → {result['sp1500']:>6,} rows")
    result["ticker_map"] = load_ticker_map(conn, tickers)
    print(f"  ticker_map      → {result['ticker_map']:>6,} rows")
    return result
