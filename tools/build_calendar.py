"""Generate the NYSE trading-session calendar used for PIT availability.

Writes ``data/reference/trading_calendar.csv`` with one row per NYSE
session: the session date, a dense sequence number, and that session's
closing time in US Eastern.

The closing time matters and is not always 16:00. On the roughly two
dozen half sessions since 2009 (day after Thanksgiving, Christmas Eve,
July 3rd in some years) the bell rings at 13:00, so a filing accepted at
14:00 on such a day is already after the close and is not actionable
until the next session.

``session_seq`` is dense and gap-free so "N trading days later" is
integer arithmetic rather than a recursive date walk.

Run:  uv run python tools/build_calendar.py
"""

from __future__ import annotations

import csv
import datetime as dt
import sys

import pandas_market_calendars as mcal

from dera_pipeline import config

# DERA coverage opens 2009-04-15; start a little earlier so the first
# filings resolve, and run well past today so forward-dated filings and
# future backtest dates always find a session.
CALENDAR_START = dt.date(2009, 1, 1)
CALENDAR_FORWARD_YEARS = 2


def build_rows(start: dt.date, end: dt.date) -> list[tuple[int, str, str, str]]:
    """Return (session_seq, session_date, close_time_et, close_at) per session.

    ``close_at`` is the closing bell as an absolute instant, written with
    its UTC offset. Storing it means the availability lookup is a single
    indexed range scan (``close_at > known_at``) instead of a
    date-plus-time comparison that no index can serve, and it gets
    daylight-saving transitions right for free.
    """
    nyse = mcal.get_calendar("NYSE")
    sched = nyse.schedule(start_date=start, end_date=end)

    # market_close is tz-aware UTC; convert to Eastern to get the real
    # local bell time, which is what filing timestamps are stamped in.
    closes = sched["market_close"].dt.tz_convert("America/New_York")

    rows: list[tuple[int, str, str, str]] = []
    for seq, (session_ts, close_ts) in enumerate(closes.items(), start=1):
        rows.append(
            (
                seq,
                session_ts.date().isoformat(),
                close_ts.strftime("%H:%M:%S"),
                close_ts.isoformat(),
            )
        )
    return rows


def main() -> int:
    end = dt.date.today() + dt.timedelta(days=365 * CALENDAR_FORWARD_YEARS)
    rows = build_rows(CALENDAR_START, end)

    if not rows:
        print("No sessions produced — aborting.", file=sys.stderr)
        return 1

    out_path = config.REFERENCE_DIR / "trading_calendar.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["session_seq", "session_date", "close_time_et", "close_at"])
        writer.writerows(rows)

    half_days = sum(1 for _, _, close, _ in rows if close < "16:00:00")
    print(f"Wrote {out_path}")
    print(f"  sessions   : {len(rows):,}")
    print(f"  range      : {rows[0][1]} .. {rows[-1][1]}")
    print(f"  half days  : {half_days:,} (close before 16:00 ET)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
