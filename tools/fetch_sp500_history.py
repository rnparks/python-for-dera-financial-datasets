"""Replay Wikipedia's S&P 500 constituents table through its revision history.

WHY. `sec_silver.universe_sp1500` is today's membership with no dates, so
every gold object that joins to it sees only companies that are in the
index now: a cross-section for 2012 scored against 2012's index is not
possible from it, and every company that left the index before today --
SVB Financial, Sears, Bed Bath & Beyond -- is simply absent. That is
survivorship bias in the one place the project had not yet removed it.

WHY WIKIPEDIA REVISIONS. S&P does not publish historical constituent
lists for free. Wikipedia's "List of S&P 500 companies" page has been
edited on every index change since well before 2009, and the MediaWiki
API serves any revision rendered as HTML. Probing one revision a month
gives a dated sequence of constituent tables, the same evidence shape as
the ticker crosswalk: sightings, never interpretation. The table has
carried a real CIK column since 2014; before that the "SEC filings" link
holds the ticker rather than a CIK, so pre-2014 rows are ticker+name
only and are resolved to CIKs downstream, in SQL, where the resolution is
auditable.

WHAT IS RECORDED. One row per (capture, ticker): the revision id and
timestamp, ticker, company name, GICS sector and sub-industry as the
page gave them on that date (GICS is therefore AS OF, which the current
snapshot never was), the CIK where the page had one, and the "date
added" where the page had one. Nothing is inferred here.

KNOWN HAZARDS, all handled downstream by the same capture-quality rules
as the crosswalk: about 1.6% of revisions are vandalised or truncated
(one 309-byte anonymous edit cut the table from 506 rows to 370), so a
capture is evidence of presence, not proof of absence; and a removed
ticker survives for months in the page's "changes" table, which is why
only the constituents table is read.

Run:  uv run python tools/fetch_sp500_history.py            # resumes
      uv run python tools/fetch_sp500_history.py --batch 0  # everything in one run
"""

from __future__ import annotations

import argparse
import csv
import gzip
import io
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import pandas as pd
from lxml import html as lxml_html

from dera_pipeline import config

API = "https://en.wikipedia.org/w/api.php"
PAGE = "List of S&P 500 companies"
INDEX_NAME = "SP500"

# One probe per month. DERA coverage opens 2009-04 and the calendar
# 2009-01; start a few months earlier so the first facts have a
# membership to join to.
PROBE_START = (2008, 10)

REQUEST_PAUSE_SECS = 1.0
TIMEOUT_SECS = 120
DEFAULT_BATCH_SIZE = 24
OUT_NAME = "sp500_history.csv.gz"

COLUMNS = ["observed_on", "revid", "ticker", "name", "cik",
           "gics_sector", "gics_sub_industry", "date_added"]


def _open_text(path, mode: str):
    if str(path).endswith(".gz"):
        return gzip.open(path, mode + "t", encoding="utf-8", newline="")
    return open(path, mode, encoding="utf-8", newline="")


def _get_json(params: dict) -> dict:
    url = API + "?" + urllib.parse.urlencode({**params, "format": "json"})
    req = urllib.request.Request(url, headers={"User-Agent": config.sec_user_agent()})
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def _probes() -> list[str]:
    y, m = PROBE_START
    today = time.gmtime()
    out = []
    while (y, m) <= (today.tm_year, today.tm_mon):
        out.append(f"{y:04d}-{m:02d}-01T00:00:00Z")
        m += 1
        if m > 12:
            y, m = y + 1, 1
    return out


def revision_at(probe: str) -> tuple[int, str] | None:
    """The latest revision at or before *probe*, as (revid, timestamp)."""
    payload = _get_json({
        "action": "query", "prop": "revisions", "titles": PAGE,
        "rvlimit": 1, "rvstart": probe, "rvdir": "older",
        "rvprop": "ids|timestamp",
    })
    pages = payload.get("query", {}).get("pages", {})
    for page in pages.values():
        revs = page.get("revisions") or []
        if revs:
            return int(revs[0]["revid"]), revs[0]["timestamp"]
    return None


def render(revid: int) -> str:
    payload = _get_json({"action": "parse", "oldid": revid, "prop": "text"})
    return payload["parse"]["text"]["*"]


def _find_col(columns: list[str], *needles: str) -> str | None:
    for col in columns:
        low = col.lower()
        if any(n in low for n in needles):
            return col
    return None


def _norm_ticker(t: str) -> str:
    return str(t).strip().upper().replace(".", "-")


def parse_constituents(page_html: str) -> list[dict]:
    """Rows of the constituents table, or [] if no plausible table exists.

    The table is the one with id="constituents" where that exists (2017
    onward), else the first table with a symbol column and at least 300
    rows. The 300 floor is deliberately low: a truncated capture must
    still be RECORDED, so the capture-quality rule downstream can see it
    is undersized, rather than silently skipped here.
    """
    doc = lxml_html.fromstring(page_html)
    candidates = doc.xpath('//table[@id="constituents"]') or doc.xpath('//table')
    for table in candidates:
        try:
            frames = pd.read_html(io.StringIO(lxml_html.tostring(table, encoding="unicode")))
        except ValueError:
            continue
        if not frames:
            continue
        df = frames[0]
        cols = [str(c) for c in df.columns]
        sym = _find_col(cols, "symbol", "ticker")
        name = _find_col(cols, "security", "company")
        if sym is None or name is None or len(df) < 300:
            continue
        df.columns = cols
        sector = _find_col(cols, "gics sector")
        sub = _find_col(cols, "gics sub")
        cik = _find_col(cols, "cik")
        added = _find_col(cols, "date added", "date first added")

        # Pre-2014 pages carry the CIK only inside the "SEC filings" link,
        # and only when the editor used a numeric one; harvest those too.
        href_cik: dict[str, str] = {}
        for tr in table.xpath(".//tr"):
            tds = tr.xpath("./td")
            if not tds:
                continue
            m = None
            for a in tr.xpath(".//a/@href"):
                m = re.search(r"CIK=(\d{1,10})", a)
                if m:
                    break
            if m:
                href_cik[_norm_ticker(tds[0].text_content())] = m.group(1)

        rows = []
        for _, r in df.iterrows():
            ticker = _norm_ticker(r[sym])
            if not ticker or ticker == "NAN":
                continue
            cik_val = ""
            if cik is not None and pd.notna(r[cik]):
                cik_val = re.sub(r"\D", "", str(r[cik]))
            if not cik_val:
                cik_val = href_cik.get(ticker, "")
            rows.append({
                "ticker": ticker,
                "name": str(r[name]).strip(),
                "cik": cik_val,
                "gics_sector": str(r[sector]).strip() if sector and pd.notna(r[sector]) else "",
                "gics_sub_industry": str(r[sub]).strip() if sub and pd.notna(r[sub]) else "",
                "date_added": str(r[added]).strip()[:10] if added and pd.notna(r[added]) else "",
            })
        return rows
    return []


def _completed_revids(path) -> set[str]:
    if not path.exists():
        return set()
    with _open_text(path, "r") as f:
        return {row["revid"] for row in csv.DictReader(f)}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--batch", type=int, default=DEFAULT_BATCH_SIZE,
                        help=f"captures to fetch this run (default {DEFAULT_BATCH_SIZE}; 0 = all)")
    args = parser.parse_args(argv)

    out_path = config.REFERENCE_DIR / OUT_NAME
    done = _completed_revids(out_path)
    if done:
        print(f"Resuming: {len(done)} revision(s) already captured.")
    fresh = not out_path.exists()
    out = _open_text(out_path, "a")
    writer = csv.DictWriter(out, fieldnames=COLUMNS)
    if fresh:
        writer.writeheader()
        out.flush()

    budget = args.batch if args.batch > 0 else 10**9
    written = 0
    try:
        for probe in _probes():
            try:
                rev = revision_at(probe)
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as exc:
                print(f"  {probe[:10]}: revision lookup failed ({exc})", file=sys.stderr)
                continue
            time.sleep(REQUEST_PAUSE_SECS)
            if rev is None:
                continue
            revid, ts = rev
            if str(revid) in done:
                continue
            try:
                rows = parse_constituents(render(revid))
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as exc:
                print(f"  {probe[:10]}: render failed for rev {revid} ({exc})", file=sys.stderr)
                continue
            time.sleep(REQUEST_PAUSE_SECS)
            day = ts[:10]
            for r in rows:
                writer.writerow({"observed_on": day, "revid": revid, **r})
            out.flush()
            done.add(str(revid))
            written += len(rows)
            with_cik = sum(1 for r in rows if r["cik"])
            print(f"  {day}  rev {revid:>10}  {len(rows):>4} rows  {with_cik:>4} with CIK")
            budget -= 1
            if budget <= 0:
                print("  batch limit reached - rerun to continue")
                break
    finally:
        out.close()

    print(f"\nWrote {out_path} (+{written:,} rows this run)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
