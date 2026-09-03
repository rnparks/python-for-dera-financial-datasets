"""Build a survivorship-free CIK to ticker crosswalk.

The problem this solves: SEC's `company_tickers.json` lists only
companies that are *currently* registered with a ticker. Every company
that delisted, was acquired, went private or went bankrupt has been
deleted from it. Measured against companies that actually filed a 10-K,
today's file is missing 58.5% of 2013 filers, 36.1% of 2019 filers and
9.0% of 2025 filers. That monotonic slope toward the present is
survivorship bias, and any universe built on the current file inherits
it.

SEC does not publish history, and the submissions API returns an empty
`tickers` array for delisted companies (verified against MOD PAC CORP
and ASSURED PHARMACY). The Internet Archive, however, has been
snapshotting `company_tickers.json` since February 2019. Replaying those
snapshots recovers companies that have since vanished from the live
file: the 2019-02 snapshot alone brings back 2,473 CIKs that filed with
SEC and are absent today.

Output is one row per (cik, ticker, observation), written to
`data/reference/ticker_history.csv`. Turning those discrete observations
into validity intervals happens in SQL, not here, so the raw evidence
stays auditable.

Coverage note: the archive starts in 2019, so companies that delisted
between 2009 and 2019 are still unrecoverable from free sources. Closing
that window needs a vendor with delisted coverage, such as Sharadar or
Norgate. This tool narrows the gap rather than eliminating it.

Run:  uv run python tools/fetch_ticker_history.py
"""

from __future__ import annotations

import csv
import gzip
import json
import sys
import time
import urllib.error
import urllib.request

from dera_pipeline import config

SEC_LIVE_URL = "https://www.sec.gov/files/company_tickers.json"
WAYBACK_AVAIL = "https://archive.org/wayback/available?url=sec.gov/files/company_tickers.json&timestamp={ts}"
WAYBACK_FETCH = "https://web.archive.org/web/{ts}id_/https://www.sec.gov/files/company_tickers.json"

# The archive's first capture is 2019-02. Two probes a year keeps the
# request count civil while still catching most delistings, since a
# company must survive a full six months to slip through unseen.
PROBE_YEARS = range(2019, 2027)
PROBE_MONTHS = ("03", "09")

REQUEST_PAUSE_SECS = 0.5
TIMEOUT_SECS = 120

# Resolving probes to real captures costs a round trip each and the
# answers never change, so cache them. This also keeps any single
# invocation short, which matters because long-lived network processes
# get reaped in some sandboxes.
STAMP_CACHE = "wayback_stamps.json"

# Snapshots to pull per invocation. Run the tool repeatedly (it resumes)
# rather than holding one long-lived process open.
BATCH_SIZE = 4


def _get_json(url: str, headers: dict[str, str] | None = None):
    """GET and decode JSON, transparently handling gzip.

    The `id_` modifier asks Wayback for the bytes exactly as archived,
    which preserves whatever Content-Encoding the origin used. SEC serves
    this file gzipped, so some captures come back as gzip while others
    (stored after upstream decoding) come back as plain text, and the
    response advertises `application/json` either way. Sniffing the gzip
    magic number is more reliable here than trusting the headers, and
    without it every compressed capture failed with a JSON decode error
    that looked like a transport problem.
    """
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as resp:
        raw = resp.read()
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    return json.loads(raw.decode("utf-8", errors="replace"))


def _normalise(payload) -> list[tuple[int, str, str]]:
    """company_tickers.json -> [(cik, ticker, title)]. Handles both the
    dict-of-records and list-of-records shapes SEC has used."""
    records = payload.values() if isinstance(payload, dict) else payload
    out: list[tuple[int, str, str]] = []
    for rec in records:
        try:
            cik = int(rec["cik_str"])
            ticker = str(rec["ticker"]).strip().upper().replace(".", "-")
            title = str(rec.get("title", ""))[:120]
        except (KeyError, TypeError, ValueError):
            continue
        if ticker:
            out.append((cik, ticker, title))
    return out


def snapshot_dates() -> list[str]:
    """Resolve each probe to the archive's nearest real capture, caching
    the answer so later invocations skip the round trips entirely."""
    cache_path = config.REFERENCE_DIR / STAMP_CACHE
    if cache_path.exists():
        try:
            return json.loads(cache_path.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    found: dict[str, str] = {}
    for year in PROBE_YEARS:
        for month in PROBE_MONTHS:
            probe = f"{year}{month}01"
            try:
                payload = _get_json(WAYBACK_AVAIL.format(ts=probe))
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
                print(f"  {probe}: availability lookup failed", file=sys.stderr)
                continue
            closest = payload.get("archived_snapshots", {}).get("closest", {})
            if closest.get("available") and closest.get("status") == "200":
                stamp = closest["timestamp"]
                found.setdefault(stamp[:8], stamp)
            time.sleep(REQUEST_PAUSE_SECS)
    stamps = [found[day] for day in sorted(found)]
    try:
        cache_path.write_text(json.dumps(stamps))
    except OSError:
        pass
    return stamps


def fetch_live() -> list[tuple[int, str, str]]:
    """Today's SEC file. Needs SEC_USER_AGENT; SEC returns 403 without a
    descriptive agent. Falls back to the local crosswalk CSV so the tool
    still runs when the variable is unset."""
    try:
        agent = config.sec_user_agent()
    except RuntimeError:
        print("  SEC_USER_AGENT unset - using local tickers.csv for 'current'")
        return _from_local_csv()
    try:
        return _normalise(_get_json(SEC_LIVE_URL, {"User-Agent": agent}))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"  live SEC fetch failed ({exc}) - using local tickers.csv")
        return _from_local_csv()


def _from_local_csv() -> list[tuple[int, str, str]]:
    path = config.REFERENCE_DIR / "tickers.csv"
    if not path.exists():
        return []
    rows: list[tuple[int, str, str]] = []
    with open(path, "r", encoding="utf-8", newline="") as f:
        for row in csv.reader(f):
            if len(row) < 3:
                continue
            try:
                rows.append(
                    (int(row[0]), row[1].strip().upper().replace(".", "-"), row[2][:120])
                )
            except ValueError:
                continue
    return rows


def _fetch_with_retry(url: str, attempts: int = 3):
    """Wayback intermittently serves an HTML error page instead of the
    archived JSON, which surfaces as a decode error rather than an HTTP
    failure. Retry those."""
    last: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            return _get_json(url)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
            last = exc
            if attempt < attempts:
                time.sleep(REQUEST_PAUSE_SECS * attempt * 2)
    raise last if last else RuntimeError("unreachable")


def _completed_sources(path) -> set[str]:
    """Sources already present in a partial CSV, so a resumed run skips
    the snapshots it already has."""
    if not path.exists():
        return set()
    done: set[str] = set()
    with open(path, "r", encoding="utf-8", newline="") as f:
        for row in csv.DictReader(f):
            src = row.get("source")
            if src:
                done.add(src)
    return done


def main() -> int:
    out_path = config.REFERENCE_DIR / "ticker_history.csv"
    done = _completed_sources(out_path)
    if done:
        print(f"Resuming: {len(done)} source(s) already collected.")

    # Append mode so a killed run never loses the snapshots it already
    # paid for. Each snapshot is flushed before the next request starts.
    fresh = not out_path.exists()
    out = open(out_path, "a", encoding="utf-8", newline="")
    writer = csv.writer(out)
    if fresh:
        writer.writerow(["cik", "ticker", "title", "observed_on", "source"])
        out.flush()

    written = 0
    try:
        print("Resolving archive snapshots...")
        stamps = snapshot_dates()
        print(f"  {len(stamps)} captures: {', '.join(s[:8] for s in stamps)}")

        budget = BATCH_SIZE
        for stamp in stamps:
            source = f"wayback:{stamp}"
            day = f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]}"
            if source in done:
                print(f"  {day}: already collected, skipping")
                continue
            try:
                payload = _fetch_with_retry(WAYBACK_FETCH.format(ts=stamp))
            except Exception as exc:  # noqa: BLE001 - report and continue
                print(f"  {day}: giving up ({type(exc).__name__}: {exc})")
                continue
            rows = _normalise(payload)
            for cik, ticker, title in rows:
                writer.writerow((cik, ticker, title, day, source))
            out.flush()
            written += len(rows)
            print(f"  {day}: {len(rows):>6,} ticker rows")
            budget -= 1
            if budget <= 0:
                print("  batch limit reached - rerun to continue")
                return 0
            time.sleep(REQUEST_PAUSE_SECS)

        if "sec_current" not in done:
            print("Fetching current SEC crosswalk...")
            today = time.strftime("%Y-%m-%d")
            live = fetch_live()
            for cik, ticker, title in live:
                writer.writerow((cik, ticker, title, today, "sec_current"))
            out.flush()
            written += len(live)
            print(f"  current: {len(live):>6,} ticker rows")
    finally:
        out.close()
        _dedupe(out_path)

    print(f"\nWrote {out_path} (+{written:,} rows this run)")
    return 0


def _dedupe(path) -> None:
    """Collapse the file to one row per (cik, ticker, observed_on).

    Resuming appends, and a run whose remaining snapshots all fail falls
    through to re-fetch the current crosswalk, so the same source can
    legitimately be written more than once across invocations. The
    database loader dedupes too, but keeping the artifact clean means
    the row counts printed here mean what they say.
    """
    if not path.exists():
        return
    seen: set[tuple[str, str, str]] = set()
    kept: list[list[str]] = []
    with open(path, "r", encoding="utf-8", newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) < 5:
                continue
            key = (row[0], row[1], row[3])
            if key in seen:
                continue
            seen.add(key)
            kept.append(row)
    with open(path, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(header)
        writer.writerows(kept)


if __name__ == "__main__":
    raise SystemExit(main())
