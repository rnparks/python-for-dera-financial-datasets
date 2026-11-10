"""Cover-page share counts from SEC's XBRL frames API.

Every 10-K and 10-Q states on its cover the common shares outstanding on a
date shortly after the period end (``dei:EntityCommonStockSharesOutstanding``),
the filer's own point-in-time count. DERA's data sets almost never carry it,
and drop some filers' share facts whole (Lockheed Martin, General Dynamics),
so it comes from SEC's frames API instead: one request per calendar quarter
returns every filer's undimensioned cover count with its accession number.

``uv run dera load-cover-shares`` fetches the quarters (cached as JSON in
``data/external/sec_frames/``, gitignored), keeps companies that were ever
index members, times each count by its filing's ``tradable_from`` and
replaces ``sec_reference.cover_share_count``
(``sql/00_reference/050_cover_share_count.sql``). ``--offline`` reloads
from the cache.

Network use is confined to ``fetch_frames``; the rest is pure or
database-only.
"""

from __future__ import annotations

import datetime as dt
import json
import time
import urllib.error
import urllib.request
from collections.abc import Iterable
from pathlib import Path

import psycopg

from . import config

FRAME_URL = ("https://data.sec.gov/api/xbrl/frames/dei/EntityCommonStockSharesOutstanding/"
             "shares/{frame}.json")
CACHE_DIR = config.PROJECT_ROOT / "data" / "external" / "sec_frames"
FIRST_YEAR = 2009


def ddl_path() -> Path:
    return config.SQL_DIR / "00_reference" / "050_cover_share_count.sql"


def frame_names(today: dt.date, first_year: int = FIRST_YEAR) -> list[str]:
    """Every calendar-quarter instant frame from ``first_year`` to the
    quarter before ``today``'s (the current quarter is still filling)."""
    current = (today.year, (today.month - 1) // 3 + 1)
    out = []
    for y in range(first_year, today.year + 1):
        for q in range(1, 5):
            if (y, q) < current:
                out.append(f"CY{y}Q{q}I")
    return out


def parse_frame(frame: str, payload: dict) -> list[tuple[int, str, dt.date, int, str]]:
    """(cik, adsh, cover_date, shares, frame) for every positive count."""
    out = []
    for r in payload.get("data", []):
        try:
            val = int(r["val"])
            if val > 0:
                out.append((int(r["cik"]), str(r["accn"]), dt.date.fromisoformat(r["end"]), val, frame))
        except (KeyError, TypeError, ValueError):
            continue
    return out


def fetch_frames(frames: Iterable[str], cache_dir: Path = CACHE_DIR, refresh_last: int = 2,
                 log=print) -> dict[str, dict]:
    """Each frame from SEC, through the cache. The newest ``refresh_last``
    frames are fetched again even when cached, because late filers keep
    adding to a quarter for weeks."""
    frames = list(frames)
    cache_dir.mkdir(parents=True, exist_ok=True)
    ua = config.sec_user_agent()
    out = {}
    for i, frame in enumerate(frames):
        path = cache_dir / f"{frame}.json"
        fresh = i >= len(frames) - refresh_last
        if path.exists() and not fresh:
            out[frame] = json.loads(path.read_text())
            continue
        req = urllib.request.Request(FRAME_URL.format(frame=frame), headers={"User-Agent": ua})
        try:
            raw = urllib.request.urlopen(req, timeout=60).read()
        except urllib.error.HTTPError as exc:
            log(f"  {frame}: HTTP {exc.code}")
            if path.exists():
                out[frame] = json.loads(path.read_text())
            continue
        path.write_bytes(raw)
        out[frame] = json.loads(raw)
        time.sleep(0.15)          # SEC asks for at most ten requests a second
    return out


def read_cache(cache_dir: Path = CACHE_DIR) -> dict[str, dict]:
    return {p.stem: json.loads(p.read_text()) for p in sorted(cache_dir.glob("CY*.json"))}


def load(conn: psycopg.Connection, payloads: dict[str, dict], log=print) -> dict:
    """Replace sec_reference.cover_share_count with the index members' cover
    counts whose filing is in DERA (its tradable_from is the count's)."""
    rows = [r for frame, p in payloads.items() for r in parse_frame(frame, p)]
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TEMP TABLE tmp_cover (cik INTEGER, adsh TEXT, cover_date DATE, shares NUMERIC, frame TEXT)
            ON COMMIT DROP
        """)
        with cur.copy("COPY tmp_cover (cik, adsh, cover_date, shares, frame) FROM STDIN") as cp:
            for r in rows:
                cp.write_row(r)
        cur.execute("TRUNCATE sec_reference.cover_share_count")
        # One row per (cik, filing, date): a count can sit in two adjacent
        # frames; the later frame's copy is the same fact.
        cur.execute("""
            INSERT INTO sec_reference.cover_share_count (cik, adsh, cover_date, shares, tradable_from, frame)
            SELECT DISTINCT ON (t.cik, t.adsh, t.cover_date)
                   t.cik, t.adsh, t.cover_date, t.shares, s.tradable_from, t.frame
            FROM tmp_cover t
            JOIN sec_silver.sub_silver s ON s.adsh = t.adsh AND s.cik = t.cik
            WHERE t.cik IN (SELECT DISTINCT cik FROM sec_reference.index_membership)
              AND s.tradable_from IS NOT NULL
              AND s.tradable_from >= t.cover_date - 400
            ORDER BY t.cik, t.adsh, t.cover_date, t.frame DESC
        """)
        loaded = cur.rowcount
        cur.execute("SELECT COUNT(DISTINCT cik) FROM sec_reference.cover_share_count")
        companies = cur.fetchone()[0]
    summary = {"frames": len(payloads), "frame_rows": len(rows), "loaded": loaded, "companies": companies}
    log(f"cover counts: {summary['frame_rows']:,} in {summary['frames']} frames; "
        f"{loaded:,} loaded for {companies:,} index companies")
    return summary
