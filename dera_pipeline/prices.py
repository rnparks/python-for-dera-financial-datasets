"""Month-end prices for index members, from Yahoo Finance.

The smallest price layer that makes the fundamentals testable: one
row per company, ticker and month end in ``sec_market.monthly_price``
(DDL in ``sql/07_market/010_monthly_price.sql``), loaded by
``uv run dera load-prices``.

What it asks for
----------------
Every OPEN listing of every company that was ever an S&P 1500 member,
from ``sec_reference.security`` and ``sec_reference.listing``. Yahoo
returns nothing for a delisted ticker and re-keys a reused ticker to its
current holder, so a closed listing is never requested: its history, if
Yahoo still had any, would belong to the wrong company. The members
with no open listing (acquired, taken private, failed) are counted and
reported; they are the survivorship gap, and no free source closes it.

One exception follows the ticker rather than the CIK: a share-for-share
successor issuer (a holding-company reorganisation or redomicile that
converted every share into one share of a new registrant under the same
ticker; ``data/reference/successor_issuers.csv``, each row citing its
8-K12B). The security did not change, so Yahoo's series is the
predecessor's before the reorganisation and the successor's after, and
the predecessor gets the months up to its handoff. Without this Exxon
Mobil (34088) had no price in any month of 2009-2026: its open listing
had passed to ExxonMobil Holdings (2115436), a registrant with no
filing in DERA yet and so no security row.

What it stores
--------------
Yahoo's split-restated close, its dividend-and-split-adjusted close
(a total-return index) and the as-traded close reconstructed from the
split ratios Yahoo reports in the month they fell. The reconstruction is
``reconstruct_raw_close`` below, a pure function with a unit test, because
the cover-page share counts in the filings are the shares that existed
then, and a split-restated price times an unrestated count is wrong by
the split.

Splits, dated
-------------
A share count is on the split basis of the day it was filed; a month-end
close on the basis of every split to that month end. ``market_cap_at``
reconciles the two with ``sec_market.split_event``, the day of every split
the monthly bars carry, fetched here from Yahoo's split history.

Point in time
-------------
A month's row is written only once that month's last NYSE session has
passed (``complete_month_ends``), so a partial month never masquerades
as a close. The accessors in the DDL take the newest month end strictly
before the knowledge date.

Network use is confined to ``fetch_monthly``; everything else is pure or
database-only, so the tests cover the logic without a vendor call.
"""

from __future__ import annotations

import datetime as dt
import re
import sys
from collections.abc import Iterable, Sequence
from dataclasses import dataclass

import psycopg

from . import config

SOURCE = "yahoo"
DEFAULT_SINCE = dt.date(2008, 1, 1)
DEFAULT_CHUNK = 250

# Listing suffixes that are not common equity: units, warrants, rights,
# preferred series. The security model already keeps those out of
# ``security``; this is the belt to its braces.
_NON_COMMON_SUFFIX = re.compile(r"-(UN|U|WT|WS|W|R|RT|P[A-Z]?)$")


@dataclass(frozen=True)
class Listing:
    cik: int
    ticker: str
    valid_from: dt.date
    first_trade_date: dt.date | None
    # The month ends this CIK is given, inclusive; None is unbounded. Only
    # a share-for-share succession sets them (``succession_windows``).
    attrib_from: dt.date | None = None
    attrib_to: dt.date | None = None


@dataclass(frozen=True)
class Succession:
    old_cik: int
    new_cik: int
    ticker: str
    effective_date: dt.date


@dataclass(frozen=True)
class PriceRow:
    cik: int
    ticker: str
    yahoo_symbol: str
    month_end: dt.date
    close_split_adj: float
    adj_close: float
    close_raw: float
    split_factor_after: float
    volume: int | None


# ----------------------------------------------------------------------
# Pure functions
# ----------------------------------------------------------------------

def yahoo_symbol(ticker: str) -> str:
    """The spine's ticker in Yahoo's spelling: a share-class dot becomes a
    dash (``BRK.B`` -> ``BRK-B``); case and whitespace are normalised."""
    return ticker.strip().upper().replace(".", "-")


def is_common_ticker(ticker: str) -> bool:
    """False for a unit, warrant, right or preferred-series ticker."""
    return _NON_COMMON_SUFFIX.search(ticker.strip().upper()) is None


def month_end_sessions(sessions: Iterable[dt.date]) -> dict[tuple[int, int], dt.date]:
    """The last trading session of every (year, month) in *sessions*."""
    out: dict[tuple[int, int], dt.date] = {}
    for d in sessions:
        key = (d.year, d.month)
        if key not in out or d > out[key]:
            out[key] = d
    return out


def complete_month_ends(
    month_ends: dict[tuple[int, int], dt.date], today: dt.date,
) -> dict[tuple[int, int], dt.date]:
    """Only the months whose last session is already behind *today*: a
    month still in progress has no close yet."""
    return {k: v for k, v in month_ends.items() if v < today}


def reconstruct_raw_close(
    closes: Sequence[tuple[dt.date, float]],
    splits: Sequence[tuple[dt.date, float]],
) -> list[tuple[dt.date, float, float]]:
    """Undo later splits.

    *closes* are (month_end, split-restated close); *splits* are
    (month_end of the month the split fell in, ratio). A month's as-traded
    close is its restated close times the product of the ratios of every
    split in a LATER month: the split month's own close is already
    post-split. Returns (month_end, close_raw, factor).
    """
    ordered = sorted((m, r) for m, r in splits if r and r > 0)
    out: list[tuple[dt.date, float, float]] = []
    for month_end, close in closes:
        factor = 1.0
        for split_month, ratio in ordered:
            if split_month > month_end:
                factor *= ratio
        out.append((month_end, close * factor, factor))
    return out


def read_successions(lines: Iterable[str]) -> list[Succession]:
    """Parse ``successor_issuers.csv`` (header included). Every row must
    cite its filing: a row without a source_note is refused, not loaded."""
    import csv
    out = []
    for row in csv.DictReader(lines):
        if not (row.get("source_note") or "").strip():
            raise ValueError(f"successor_issuers.csv: {row.get('ticker')} has no source_note")
        out.append(Succession(int(row["old_cik"]), int(row["new_cik"]),
                              row["ticker"].strip().upper(),
                              dt.date.fromisoformat(row["effective_date"])))
    return out


def succession_windows(
    effective: dt.date, handoff: dt.date | None, month_ends: Iterable[dt.date],
) -> tuple[dt.date | None, dt.date | None]:
    """The month ends on either side of a share-for-share succession.

    The predecessor keeps every month end up to and including the first
    one on or after the later of the reorganisation and the crosswalk's
    handoff, so the month it last held the seat still has a closing
    price for its return. The successor starts at the last month end
    before the reorganisation, so its first month has a prior close.
    The overlap is the point: each side has a complete first or last
    month, and the membership decides which CIK is held on any date.
    Returns (predecessor's last month end, successor's first)."""
    ends = sorted(month_ends)
    switch = max(effective, handoff) if handoff else effective
    pred_last = next((m for m in ends if m >= switch), None)
    succ_first = next((m for m in reversed(ends) if m < effective), None)
    return pred_last, succ_first


def split_event_rows(
    events: dict[str, Sequence[tuple[dt.date, float]]],
    tickers_by_symbol: dict[str, Iterable[str]],
) -> list[tuple[str, str, dt.date, float]]:
    """(ticker, yahoo_symbol, split_date, ratio) for every split of every
    symbol, once per spine ticker the symbol prices; a ratio of 1, or one
    that is not positive, is no split and is dropped."""
    out = set()
    for sym, evs in events.items():
        for ticker in tickers_by_symbol.get(sym, ()):
            for d, r in evs:
                if r and r > 0 and abs(r - 1) > 1e-9:
                    out.add((ticker, sym, d, float(r)))
    return sorted(out)


def chunks(seq: Sequence[str], size: int) -> Iterable[Sequence[str]]:
    for i in range(0, len(seq), size):
        yield seq[i:i + size]


# ----------------------------------------------------------------------
# Database reads
# ----------------------------------------------------------------------

def member_listings(conn: psycopg.Connection) -> list[Listing]:
    """Every open listing that is (or was) the PRIMARY ticker of a company
    that was ever an index member: one series per company. The listing
    table also carries preferred series, baby bonds, rights and second
    share classes under plain tickers (WFCNP, DUKB, GENVR, GOOGL); their
    Yahoo series are sparse or priced in another unit, and they are not
    what a backtest holds."""
    sql = """
        SELECT s.cik, l.ticker, MIN(l.valid_from) AS valid_from, MIN(s.first_trade_date)
        FROM sec_reference.security s
        JOIN sec_reference.listing  l USING (security_id)
        WHERE l.valid_to = DATE '9999-12-31'
          AND s.delisting_date IS NULL
          AND s.cik IN (SELECT DISTINCT cik FROM sec_reference.index_membership)
          AND EXISTS (SELECT 1 FROM sec_reference.company_ticker ct
                       WHERE ct.cik = s.cik AND ct.ticker = l.ticker AND ct.is_primary)
        GROUP BY s.cik, l.ticker
        ORDER BY s.cik, l.ticker
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        return [Listing(int(c), t, vf, ft) for c, t, vf, ft in cur.fetchall()
                if is_common_ticker(t)]


def members_without_open_listing(conn: psycopg.Connection) -> int:
    sql = """
        SELECT COUNT(*) FROM (SELECT DISTINCT cik FROM sec_reference.index_membership) m
        WHERE m.cik NOT IN (
            SELECT s.cik FROM sec_reference.security s
            JOIN sec_reference.listing l USING (security_id)
            WHERE l.valid_to = DATE '9999-12-31' AND s.delisting_date IS NULL)
    """
    with conn.cursor() as cur:
        cur.execute(sql)
        return int(cur.fetchone()[0])


def successions_path():
    return config.REFERENCE_DIR / "successor_issuers.csv"


def succession_listings(
    conn: psycopg.Connection, successions: Sequence[Succession],
    month_ends: Iterable[dt.date], have: Iterable[Listing],
) -> list[Listing]:
    """The listings a share-for-share succession adds: the predecessor,
    when it was an index member, for the months up to its handoff; and
    the successor from the month before the reorganisation, but only when
    it has no open listing of the ticker already (a registrant with no
    filing in DERA yet has no security row, so ``member_listings`` cannot
    see it: ExxonMobil Holdings until its first 10-Q)."""
    ends = list(month_ends)
    held = {(lst.cik, lst.ticker) for lst in have}
    out: list[Listing] = []
    with conn.cursor() as cur:
        for sc in successions:
            cur.execute("""
                SELECT (SELECT MAX(handoff_date) FROM sec_reference.cik_succession
                         WHERE old_cik = %(o)s AND new_cik = %(n)s AND ticker = %(t)s),
                       EXISTS (SELECT 1 FROM sec_reference.index_membership WHERE cik = %(o)s),
                       EXISTS (SELECT 1 FROM sec_reference.index_membership WHERE cik = %(n)s),
                       (SELECT MIN(first_trade_date) FROM sec_reference.security WHERE cik = %(o)s)
            """, {"o": sc.old_cik, "n": sc.new_cik, "t": sc.ticker})
            handoff, old_member, new_member, old_first = cur.fetchone()
            pred_last, succ_first = succession_windows(sc.effective_date, handoff, ends)
            if old_member and pred_last and (sc.old_cik, sc.ticker) not in held:
                out.append(Listing(sc.old_cik, sc.ticker, sc.effective_date, old_first,
                                   attrib_to=pred_last))
            if new_member and succ_first and (sc.new_cik, sc.ticker) not in held:
                out.append(Listing(sc.new_cik, sc.ticker, sc.effective_date, None,
                                   attrib_from=succ_first))
    return out


def trading_sessions(conn: psycopg.Connection) -> list[dt.date]:
    with conn.cursor() as cur:
        cur.execute("SELECT session_date FROM sec_reference.trading_calendar ORDER BY 1")
        return [r[0] for r in cur.fetchall()]


# ----------------------------------------------------------------------
# The vendor call
# ----------------------------------------------------------------------

def fetch_monthly(
    symbols: Sequence[str], since: dt.date, chunk: int = DEFAULT_CHUNK,
    log=print,
) -> dict[str, list[dict]]:
    """Monthly bars per symbol from Yahoo: one dict per month with the
    (year, month), split-restated close, adjusted close, volume and the
    split ratio that fell in the month (0 when none). Symbols Yahoo
    does not know are simply absent from the result."""
    import pandas as pd  # noqa: F401  (yfinance returns DataFrames)
    import yfinance as yf

    out: dict[str, list[dict]] = {}
    for i, batch in enumerate(chunks(list(symbols), chunk), start=1):
        log(f"  batch {i}: {len(batch)} symbols")
        df = yf.download(
            list(batch), start=since.isoformat(), interval="1mo",
            auto_adjust=False, actions=True, group_by="ticker",
            threads=True, progress=False,
        )
        if df is None or df.empty:
            continue
        for sym in batch:
            try:
                frame = df[sym] if isinstance(df.columns, pd.MultiIndex) else df
            except KeyError:
                continue
            if "Close" not in frame.columns:
                continue
            frame = frame.dropna(subset=["Close"])
            if frame.empty:
                continue
            rows = []
            for idx, r in frame.iterrows():
                d = idx.date() if hasattr(idx, "date") else idx
                close = float(r["Close"])
                adj = float(r["Adj Close"]) if "Adj Close" in frame.columns else close
                if not (close > 0 and adj > 0):
                    continue
                vol = r.get("Volume")
                split = r.get("Stock Splits", 0.0)
                rows.append({
                    "ym": (d.year, d.month),
                    "close": close,
                    "adj": adj,
                    "volume": int(vol) if vol == vol and vol is not None else None,
                    "split": float(split) if split == split and split else 0.0,
                })
            if rows:
                out[sym] = rows
    return out


def fetch_split_events(symbols: Sequence[str], log=print) -> dict[str, list[tuple[dt.date, float]]]:
    """Every split Yahoo records for each symbol, dated to the first
    session on the new basis (yfinance ``Ticker.splits``). Monthly bars say
    only which month a split fell in; ``market_cap_at`` needs the day."""
    import yfinance as yf

    out: dict[str, list[tuple[dt.date, float]]] = {}
    for i, sym in enumerate(symbols, start=1):
        try:
            sp = yf.Ticker(sym).splits
        except Exception as exc:  # noqa: BLE001  (a vendor error skips one symbol)
            log(f"  splits {sym}: {exc}")
            continue
        out[sym] = [(d.date(), float(r)) for d, r in sp.items()]
        if i % 100 == 0:
            log(f"  splits: {i} of {len(symbols)} symbols")
    return out


def write_split_events(conn: psycopg.Connection, rows: Sequence[tuple[str, str, dt.date, float]]) -> int:
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.executemany("""
            INSERT INTO sec_market.split_event (ticker, yahoo_symbol, split_date, ratio, source, fetched_at)
            VALUES (%s, %s, %s, %s, 'yahoo', now())
            ON CONFLICT (ticker, split_date) DO UPDATE SET
                yahoo_symbol = EXCLUDED.yahoo_symbol, ratio = EXCLUDED.ratio, fetched_at = now()
        """, rows)
    return len(rows)


def load_split_events(conn: psycopg.Connection, tickers_by_symbol: dict[str, Iterable[str]], log=print) -> int:
    """Fetch and upsert the dated splits of the given symbols."""
    events = fetch_split_events(sorted(tickers_by_symbol), log=log)
    return write_split_events(conn, split_event_rows(events, tickers_by_symbol))


# ----------------------------------------------------------------------
# Assembly
# ----------------------------------------------------------------------

def build_rows(
    listing: Listing, symbol: str, bars: Sequence[dict],
    month_ends: dict[tuple[int, int], dt.date],
) -> list[PriceRow]:
    """Price rows for one listing: months mapped to their last session,
    partial months and months before the security traded dropped, the
    as-traded close reconstructed."""
    dated = []
    for b in bars:
        me = month_ends.get(b["ym"])
        if me is None:
            continue
        if listing.first_trade_date and me < listing.first_trade_date:
            continue
        if listing.attrib_from and me < listing.attrib_from:
            continue
        if listing.attrib_to and me > listing.attrib_to:
            continue
        dated.append((me, b))
    dated.sort(key=lambda x: x[0])
    closes = [(me, b["close"]) for me, b in dated]
    splits = [(me, b["split"]) for me, b in dated if b["split"] > 0]
    raw = reconstruct_raw_close(closes, splits)
    rows = []
    for (me, b), (_, close_raw, factor) in zip(dated, raw, strict=True):
        rows.append(PriceRow(
            cik=listing.cik, ticker=listing.ticker, yahoo_symbol=symbol,
            month_end=me, close_split_adj=b["close"], adj_close=b["adj"],
            close_raw=close_raw, split_factor_after=factor, volume=b["volume"],
        ))
    return rows


def write_rows(conn: psycopg.Connection, rows: Sequence[PriceRow]) -> int:
    """Upsert into sec_market.monthly_price through a temp table and COPY."""
    if not rows:
        return 0
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TEMP TABLE tmp_monthly_price
            (LIKE sec_market.monthly_price INCLUDING DEFAULTS) ON COMMIT DROP
        """)
        cols = ("cik", "ticker", "yahoo_symbol", "month_end", "close_split_adj",
                "adj_close", "close_raw", "split_factor_after", "volume", "source")
        with cur.copy(f"COPY tmp_monthly_price ({', '.join(cols)}) FROM STDIN") as cp:
            for r in rows:
                cp.write_row((r.cik, r.ticker, r.yahoo_symbol, r.month_end,
                              r.close_split_adj, r.adj_close, r.close_raw,
                              r.split_factor_after, r.volume, SOURCE))
        cur.execute("""
            INSERT INTO sec_market.monthly_price
                (cik, ticker, yahoo_symbol, month_end, close_split_adj, adj_close,
                 close_raw, split_factor_after, volume, source, fetched_at)
            SELECT cik, ticker, yahoo_symbol, month_end, close_split_adj, adj_close,
                   close_raw, split_factor_after, volume, source, now()
            FROM tmp_monthly_price
            ON CONFLICT (cik, ticker, month_end) DO UPDATE SET
                yahoo_symbol = EXCLUDED.yahoo_symbol,
                close_split_adj = EXCLUDED.close_split_adj,
                adj_close = EXCLUDED.adj_close,
                close_raw = EXCLUDED.close_raw,
                split_factor_after = EXCLUDED.split_factor_after,
                volume = EXCLUDED.volume,
                source = EXCLUDED.source,
                fetched_at = now()
        """)
        return cur.rowcount


def record_load(conn: psycopg.Connection, summary: dict) -> None:
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO sec_market.price_load
                (source, symbols_requested, symbols_returned, rows_written,
                 first_month, last_month, members_without_listing, note)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s)
        """, (SOURCE, summary["symbols_requested"], summary["symbols_returned"],
              summary["rows_written"], summary["first_month"], summary["last_month"],
              summary["members_without_listing"], summary.get("note")))


def load_prices(
    conn: psycopg.Connection, *, since: dt.date = DEFAULT_SINCE,
    tickers: Sequence[str] | None = None, chunk: int = DEFAULT_CHUNK,
    today: dt.date | None = None, until: dt.date | None = None, log=print,
) -> dict:
    """Fetch and upsert month-end prices for the member universe (or the
    given tickers), and record the load. *until* caps the last month end
    written, so a backfill of a few tickers can stop where the table
    does. Returns the summary."""
    today = today or dt.date.today()
    month_ends = complete_month_ends(month_end_sessions(trading_sessions(conn)), today)
    if until:
        month_ends = {k: v for k, v in month_ends.items() if v <= until}
    listings = member_listings(conn)
    with open(successions_path(), encoding="utf-8") as fh:
        successions = read_successions(fh)
    listings += succession_listings(conn, successions, month_ends.values(), listings)
    if tickers:
        wanted = {t.strip().upper() for t in tickers}
        listings = [lst for lst in listings if lst.ticker.upper() in wanted]
    by_symbol: dict[str, list[Listing]] = {}
    for lst in listings:
        by_symbol.setdefault(yahoo_symbol(lst.ticker), []).append(lst)
    symbols = sorted(by_symbol)
    log(f"{len(listings)} open listings of index members, {len(symbols)} symbols; "
        f"months complete through {max(month_ends.values()) if month_ends else None}")

    bars = fetch_monthly(symbols, since, chunk, log=log)
    rows: list[PriceRow] = []
    for sym, series in bars.items():
        for lst in by_symbol[sym]:
            rows.extend(build_rows(lst, sym, series, month_ends))
    written = write_rows(conn, rows)
    # The day of every split the monthly bars carry, for market_cap_at.
    split_symbols = {sym: {lst.ticker for lst in by_symbol[sym]}
                     for sym, series in bars.items() if any(b["split"] for b in series)}
    splits = load_split_events(conn, split_symbols, log=log) if split_symbols else 0
    missing = sorted(set(symbols) - set(bars))
    summary = {
        "symbols_requested": len(symbols),
        "symbols_returned": len(bars),
        "rows_written": written,
        "first_month": min((r.month_end for r in rows), default=None),
        "last_month": max((r.month_end for r in rows), default=None),
        "members_without_listing": members_without_open_listing(conn),
        "missing_symbols": missing,
        "note": f"since {since}; {len(missing)} symbols returned nothing; {splits} dated splits",
        "split_events": splits,
    }
    record_load(conn, summary)
    return summary


def ddl_path():
    return config.SQL_DIR / "07_market" / "010_monthly_price.sql"


def print_summary(summary: dict, out=sys.stdout) -> None:
    out.write(
        f"symbols requested {summary['symbols_requested']}, returned "
        f"{summary['symbols_returned']}, rows written {summary['rows_written']}, "
        f"months {summary['first_month']} to {summary['last_month']}\n"
        f"members ever with no open listing (no prices possible from this source): "
        f"{summary['members_without_listing']}\n"
    )
    if summary["missing_symbols"]:
        sample = ", ".join(summary["missing_symbols"][:20])
        out.write(f"symbols Yahoo returned nothing for ({len(summary['missing_symbols'])}): "
                  f"{sample}{' ...' if len(summary['missing_symbols']) > 20 else ''}\n")


# ----------------------------------------------------------------------
# The factor panel
# ----------------------------------------------------------------------

def panel_dates(
    month_ends: Iterable[dt.date], since: dt.date, until: dt.date | None,
) -> list[dt.date]:
    """The month ends to build, quarter ends first (so a quarterly
    backtest is possible early), then the rest, each group in order."""
    ends = sorted(d for d in month_ends if d >= since and (until is None or d <= until))
    quarter = [d for d in ends if d.month in (3, 6, 9, 12)]
    other = [d for d in ends if d.month not in (3, 6, 9, 12)]
    return quarter + other


# Combined universes: a name, and the component panels it is the union
# of (sec_market.build_factor_panel dispatches 'SP1500' to the re-rank).
UNION_PANELS = {"SP1500": ("SP500", "SP400", "SP600")}


def build_factor_panel(
    conn: psycopg.Connection, *, index: str, since: dt.date,
    until: dt.date | None = None, rebuild: bool = False,
    today: dt.date | None = None, log=print,
) -> int:
    """Call sec_market.build_factor_panel for every month end in range,
    committing each date. Returns the number of dates built."""
    today = today or dt.date.today()
    ends = complete_month_ends(month_end_sessions(trading_sessions(conn)), today).values()
    dates = panel_dates(ends, since, until)
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT asof FROM sec_market.factor_panel WHERE index_name = %s", (index,))
        have = {r[0] for r in cur.fetchall()}
        if index in UNION_PANELS:
            # A union is a re-rank of its component panels: only the
            # dates every component already holds can be built.
            components = UNION_PANELS[index]
            cur.execute(
                "SELECT asof FROM sec_market.factor_panel WHERE index_name = ANY(%s) "
                "GROUP BY asof HAVING count(DISTINCT index_name) = %s", (list(components), len(components)))
            complete = {r[0] for r in cur.fetchall()}
            skipped = [d for d in dates if d not in complete]
            dates = [d for d in dates if d in complete]
            log(f"{index} = {' + '.join(components)}: {len(skipped)} month ends skipped where a component is not built")
    todo = [d for d in dates if rebuild or d not in have]
    log(f"{index}: {len(dates)} month ends in range, {len(have)} already built, {len(todo)} to build")
    built = 0
    for i, d in enumerate(todo, start=1):
        started = dt.datetime.now()
        with conn.cursor() as cur:
            cur.execute("SELECT sec_market.build_factor_panel(%s, %s)", (index, d))
            n = cur.fetchone()[0]
        conn.commit()
        built += 1
        log(f"  {i}/{len(todo)} {d}: {n} rows in {(dt.datetime.now() - started).seconds} s")
    return built
