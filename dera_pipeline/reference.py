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
import datetime as dt
import gzip
from pathlib import Path

import psycopg

from . import config

# A calendar that ends too soon is a silent failure, not a loud one:
# `sub_silver` LEFT JOINs the calendar to resolve `tradable_from`, so a
# filing accepted after the last session simply gets NULL and vanishes
# from every as-of slice. The calendar is generated two years ahead;
# refuse to load one with less than a year left so the rebuild that
# would have produced NULLs stops before it starts.
CALENDAR_MIN_HORIZON = dt.timedelta(days=365)


def load_sp1500_universe(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/sp1500_universe.csv → sec_silver.universe_sp1500.

    Expects columns ``ticker, name, index_name, gics_sector,
    gics_sub_industry``. Older CSVs without the GICS columns still load
    cleanly — missing columns are stored as NULL.
    """
    seen: dict[str, tuple[str, str, str, str | None, str | None]] = {}
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            ticker = row["ticker"].replace(".", "-")
            if ticker in seen:
                continue
            # Empty strings from the CSV read become None so Postgres
            # stores a true NULL rather than a blank string.
            gics_sector = row.get("gics_sector") or None
            gics_sub = row.get("gics_sub_industry") or None
            seen[ticker] = (
                ticker, row["name"], row["index_name"], gics_sector, gics_sub
            )

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_silver.universe_sp1500")
        with cur.copy(
            "COPY sec_silver.universe_sp1500 "
            "(ticker, name, index_name, gics_sector, gics_sub_industry) "
            "FROM STDIN WITH (FORMAT CSV, DELIMITER E'\\t')"
        ) as cp:
            for row_tuple in seen.values():
                cp.write_row(row_tuple)
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


def load_trading_calendar(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/trading_calendar.csv → sec_reference.trading_calendar.

    Expects a header row and columns ``session_seq, session_date,
    close_time_et``. Must run *before* the silver build, because
    `sub_silver` needs these rows to resolve `tradable_from`.
    """
    rows: list[tuple[str, int, str, str]] = []
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            rows.append(
                (
                    row["session_date"],
                    int(row["session_seq"]),
                    row["close_time_et"],
                    row["close_at"],
                )
            )

    if not rows:
        raise ValueError(f"{csv_path} contained no sessions")

    last_session = dt.date.fromisoformat(max(r[0] for r in rows))
    if last_session - dt.date.today() < CALENDAR_MIN_HORIZON:
        raise ValueError(
            f"{csv_path} ends {last_session}, less than a year from today. "
            "Filings accepted after the last session would get a NULL "
            "tradable_from and silently drop out of every as-of query. "
            "Regenerate with `uv run python tools/build_calendar.py` "
            "(it writes two years ahead) before rebuilding silver."
        )

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_reference.trading_calendar")
        with cur.copy(
            "COPY sec_reference.trading_calendar "
            "(session_date, session_seq, close_time_et, close_at) "
            "FROM STDIN WITH (FORMAT CSV, DELIMITER E'\\t')"
        ) as cp:
            for row_tuple in rows:
                cp.write_row(row_tuple)
    return len(rows)


def _open_text(path: Path, mode: str = "r"):
    """Open a reference file for text reading, gzip-transparently by suffix."""
    if path.suffix == ".gz":
        return gzip.open(path, mode + "t", encoding="utf-8", newline="")
    return open(path, mode, encoding="utf-8", newline="")


def load_ticker_history(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/ticker_history.csv(.gz) → sec_reference.ticker_observation.

    Raw dated sightings of CIK/ticker pairs across snapshots of SEC's
    company_tickers.json. Deliberately append-only evidence; the
    validity intervals are derived from it in
    `sql/05_spine/010_company_spine.sql`.

    A pair can legitimately appear in many snapshots, and the same
    snapshot day can be reached by more than one probe, so the primary
    key collision is expected and skipped rather than treated as an
    error.
    """
    seen: set[tuple[int, str, str]] = set()
    rows: list[tuple[int, str, str, str, str]] = []
    with _open_text(csv_path) as f:
        for row in csv.DictReader(f):
            try:
                cik = int(row["cik"])
            except (KeyError, ValueError):
                continue
            ticker = row["ticker"].strip().upper()
            observed = row["observed_on"]
            if not ticker or (cik, ticker, observed) in seen:
                continue
            seen.add((cik, ticker, observed))
            rows.append((cik, ticker, row.get("title") or None, observed,
                         row.get("source") or "unknown"))

    if not rows:
        raise ValueError(f"{csv_path} contained no observations")

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_reference.ticker_observation")
        with cur.copy(
            "COPY sec_reference.ticker_observation "
            "(cik, ticker, title, observed_on, source) "
            "FROM STDIN WITH (FORMAT CSV, DELIMITER E'\\t')"
        ) as cp:
            for row_tuple in rows:
                cp.write_row(row_tuple)
    return len(rows)


def load_share_class_map(conn: psycopg.Connection, csv_path: Path) -> int:
    """Load data/reference/share_class_map.csv → sec_reference.share_class.

    Explicit mappings only. Single-class issuers are inferred
    deterministically downstream and must NOT appear here, so this file
    stays small enough to review in a pull request.

    Blank strings become NULL rather than empty text, because the table's
    CHECK constraints distinguish "no ticker" from "" and would otherwise
    accept a row that is neither listed, priced-with, nor excluded.
    """
    def nn(v: str | None) -> str | None:
        v = (v or "").strip()
        return v or None

    rows: list[tuple] = []
    with open(csv_path, "r", encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            try:
                cik = int(r["cik"])
            except (KeyError, ValueError):
                continue
            label = nn(r.get("class_label"))
            if not label:
                continue
            ratio = nn(r.get("conversion_ratio"))
            rows.append((
                cik,
                label,
                nn(r.get("ticker")),
                nn(r.get("prices_with_ticker")),
                float(ratio) if ratio else None,
                (r.get("is_excluded") or "false").strip().lower() == "true",
                nn(r.get("effective_from")) or "1900-01-01",
                nn(r.get("effective_to")),
                nn(r.get("source")) or "mapped_filing",
                nn(r.get("source_note")),
            ))

    if not rows:
        raise ValueError(f"{csv_path} contained no share-class mappings")

    with conn.cursor() as cur:
        cur.execute("TRUNCATE TABLE sec_reference.share_class")
        with cur.copy(
            # Text format, not CSV: psycopg writes None as the \N NULL
            # marker, which CSV mode treats as the literal two-character
            # string and rejects on a numeric column. Several columns here
            # are legitimately NULL (an unlisted class has no ticker), so
            # text format is the correct choice rather than a workaround.
            "COPY sec_reference.share_class "
            "(cik, class_label, ticker, prices_with_ticker, conversion_ratio, "
            " is_excluded, effective_from, effective_to, source, source_note) "
            "FROM STDIN"
        ) as cp:
            for row in rows:
                cp.write_row(row)
    return len(rows)


def load_calendar_only(conn: psycopg.Connection) -> int:
    """Load the pre-silver reference data, in `sec_reference`.

    Three tables, not one: the trading calendar (required — `sub_silver`
    resolves `tradable_from` against it during its own build), plus the
    ticker-history observations and the share-class map, both optional
    and skipped with a message when their CSVs are absent.

    All three live in `sec_reference` precisely so the
    DROP SCHEMA sec_silver CASCADE at the top of the silver build does
    not take them out.
    """
    calendar = config.REFERENCE_DIR / "trading_calendar.csv"
    if not calendar.exists():
        raise FileNotFoundError(
            f"{calendar} missing — generate with "
            "`uv run python tools/build_calendar.py`"
        )
    n = load_trading_calendar(conn, calendar)
    print(f"  trading_calendar → {n:>6,} sessions")

    # Ticker history is optional: the pipeline still builds without it,
    # it just falls back to the survivorship-biased current crosswalk.
    history = config.REFERENCE_DIR / "ticker_history.csv.gz"
    if not history.exists():
        history = config.REFERENCE_DIR / "ticker_history.csv"
    if history.exists():
        h = load_ticker_history(conn, history)
        print(f"  ticker_observation → {h:>6,} dated sightings")
    else:
        print(
            "  ticker_history.csv.gz absent — crosswalk will be "
            "current-only (survivorship biased). Build it with "
            "`uv run python tools/fetch_ticker_history.py`."
        )

    # Optional: without it, multi-class issuers simply resolve no
    # per-class shares rather than resolving wrong ones.
    sc = config.REFERENCE_DIR / "share_class_map.csv"
    if sc.exists():
        m = load_share_class_map(conn, sc)
        print(f"  share_class      → {m:>6,} class mappings")
    else:
        print("  share_class_map.csv absent — no per-class share data")
    return n


def load_all_reference(conn: psycopg.Connection) -> dict[str, int]:
    """Load the post-silver reference tables: universe_sp1500, ticker_map.

    Not "every reference table" — the calendar, ticker history and
    share-class map are loaded earlier by `load_calendar_only`, because
    the silver build depends on them. These two are loaded after silver
    exists because they live in the `sec_silver` schema it creates.
    """
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
