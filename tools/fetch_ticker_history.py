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
snapshotting `company_tickers.json` since December 2018. Replaying those
snapshots recovers companies that have since vanished from the live
file: the 2019-02 snapshot alone brings back 2,473 CIKs that filed with
SEC and are absent today.

Output is one row per (cik, ticker, observation), written to
`data/reference/ticker_history.csv.gz`. Turning those discrete observations
into validity intervals happens in SQL, not here, so the raw evidence
stays auditable.

TWO RULES THAT WERE LEARNED THE HARD WAY.

1. A capture is evidence of presence, never proof of absence on its own.
   Wayback captures are sometimes partial: the 2023-09-02 capture holds
   8,933 rows against 11,112 six months earlier and 10,492 six months
   later, and on its own it manufactured 1,019 false "ticker retired"
   gaps. The interval derivation in sql/05_spine/010_company_spine.sql
   therefore flags undersized captures and bridges single-capture gaps.
   This tool's job is to fetch as many captures as the archive has --
   monthly probes, not two a year -- so that a false absence is bounded
   by weeks rather than by half a year.

2. The live file is fetched or it is not written. An earlier version fell
   back to the local `tickers.csv` when the live fetch failed and stamped
   those rows with today's date as `sec_current`. The database then
   carried a nine-month-old file labelled as the present, resurrecting
   1,334 retired tickers (Electronic Arts among them) as "still current".
   A missing observation is recoverable by re-running; a fabricated one
   is not, because nothing downstream can tell it from a real one.

Coverage note: the archive starts in December 2018. The spine extends a
single-ticker history back to the company's first filing (flagged as
inferred), but a company that delisted between 2009 and 2018 and never
appeared in the file is still unrecoverable from free sources. Closing
that window needs a vendor with delisted coverage. This tool narrows the
gap rather than eliminating it.

Run:  uv run python tools/fetch_ticker_history.py
      uv run python tools/fetch_ticker_history.py --batch 0        # all captures in one run
      uv run python tools/fetch_ticker_history.py --purge-source sec_current
"""

from __future__ import annotations

import argparse
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

# The archive's first capture is 2018-12-26. One probe a month: a ticker
# that disappears is then bounded to a few weeks, and a single partial
# capture is bracketed by good ones on both sides, which is what the
# bridging rule in the spine needs. 96 availability lookups in total.
PROBE_YEARS = range(2019, 2027)
PROBE_MONTHS = tuple(f"{m:02d}" for m in range(1, 13))

REQUEST_PAUSE_SECS = 0.5
TIMEOUT_SECS = 120

# Resolving probes to real captures costs a round trip each and the
# answers never change, so cache them. The cache records the probe set it
# was built from, so widening the probes invalidates it automatically.
STAMP_CACHE = "wayback_stamps.json"

# Captures to pull per invocation by default. Run the tool repeatedly (it
# resumes) rather than holding one long-lived process open; pass
# --batch 0 to fetch everything in one go.
DEFAULT_BATCH_SIZE = 8

LIVE_SOURCE = "sec_current"

# Gzipped on disk. Monthly captures took the plain CSV to 62 MB, past
# GitHub's 50 MB warning; compressed it is about a quarter of that. Every
# reader and writer below goes through _open_text so the format is a
# detail of the filename, and the loader accepts either form.
OUT_NAME = "ticker_history.csv.gz"


def _open_text(path, mode: str):
    """Open *path* for text I/O, gzip-transparently by suffix."""
    if str(path).endswith(".gz"):
        return gzip.open(path, mode + "t", encoding="utf-8", newline="")
    return open(path, mode, encoding="utf-8", newline="")


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


def _probes() -> list[str]:
    return [f"{y}{m}01" for y in PROBE_YEARS for m in PROBE_MONTHS]


def snapshot_dates() -> list[str]:
    """Resolve each probe to the archive's nearest real capture, caching
    the answer so later invocations skip the round trips entirely.

    The cache is keyed on the probe list. A cache written by the older
    twice-a-year version is a bare list and is discarded, so the first run
    after widening the probes re-resolves everything once.
    """
    probes = _probes()
    cache_path = config.REFERENCE_DIR / STAMP_CACHE
    if cache_path.exists():
        try:
            cached = json.loads(cache_path.read_text())
            if isinstance(cached, dict) and cached.get("probes") == probes:
                return list(cached["stamps"])
            print("  stamp cache is from a different probe set - re-resolving")
        except (json.JSONDecodeError, OSError, KeyError, TypeError):
            pass
    found: dict[str, str] = {}
    for probe in probes:
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
        cache_path.write_text(json.dumps({"probes": probes, "stamps": stamps}))
    except OSError:
        pass
    return stamps


def fetch_live() -> list[tuple[int, str, str]] | None:
    """Today's SEC file, or None if it could not be fetched.

    Needs SEC_USER_AGENT; SEC returns 403 without a descriptive agent.
    There is deliberately no fallback to a local file: a stale file
    stamped with today's date is worse than no observation at all (see
    the module docstring), so a failure here is reported and the run
    simply carries no live snapshot. Re-run when the network is back.
    """
    agent = config.sec_user_agent()  # raises if unset: no silent placeholder
    try:
        return _normalise(_get_json(SEC_LIVE_URL, {"User-Agent": agent}))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"  live SEC fetch FAILED ({exc}); no '{LIVE_SOURCE}' rows "
              "written this run. Re-run to retry.", file=sys.stderr)
        return None


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
    with _open_text(path, "r") as f:
        for row in csv.DictReader(f):
            src = row.get("source")
            if src:
                done.add(src)
    return done


def _purge_sources(path, sources: set[str]) -> int:
    """Remove every row whose source is in *sources*. Returns rows removed.

    Exists for one reason: the fabricated `sec_current` rows described in
    the module docstring had to be removed once, auditable from the
    command line rather than by hand-editing an 11 MB file.
    """
    if not path.exists() or not sources:
        return 0
    kept: list[list[str]] = []
    removed = 0
    with _open_text(path, "r") as f:
        reader = csv.reader(f)
        header = next(reader, None)
        for row in reader:
            if len(row) >= 5 and row[4] in sources:
                removed += 1
                continue
            kept.append(row)
    with _open_text(path, "w") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(header)
        writer.writerows(kept)
    return removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--batch", type=int, default=DEFAULT_BATCH_SIZE,
        help=f"captures to fetch this run (default {DEFAULT_BATCH_SIZE}; 0 = all)")
    parser.add_argument(
        "--purge-source", action="append", default=[], metavar="SOURCE",
        help="remove rows with this source before fetching (repeatable)")
    parser.add_argument(
        "--skip-live", action="store_true",
        help="do not fetch the live SEC file this run")
    args = parser.parse_args(argv)

    out_path = config.REFERENCE_DIR / OUT_NAME
    if args.purge_source:
        n = _purge_sources(out_path, set(args.purge_source))
        print(f"Purged {n:,} row(s) with source in {sorted(set(args.purge_source))}")

    done = _completed_sources(out_path)
    if done:
        print(f"Resuming: {len(done)} source(s) already collected.")

    # Append mode so a killed run never loses the snapshots it already
    # paid for. Each snapshot is flushed before the next request starts.
    fresh = not out_path.exists()
    out = _open_text(out_path, "a")
    writer = csv.writer(out)
    if fresh:
        writer.writerow(["cik", "ticker", "title", "observed_on", "source"])
        out.flush()

    written = 0
    try:
        print("Resolving archive snapshots...")
        stamps = snapshot_dates()
        print(f"  {len(stamps)} captures: {', '.join(s[:8] for s in stamps)}")

        budget = args.batch if args.batch > 0 else len(stamps) + 1
        for stamp in stamps:
            source = f"wayback:{stamp}"
            day = f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]}"
            if source in done:
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

        if not args.skip_live:
            print("Fetching current SEC crosswalk...")
            today = time.strftime("%Y-%m-%d")
            live = fetch_live()
            if live is not None:
                for cik, ticker, title in live:
                    writer.writerow((cik, ticker, title, today, LIVE_SOURCE))
                out.flush()
                written += len(live)
                print(f"  current ({today}): {len(live):>6,} ticker rows")
    finally:
        out.close()
        _dedupe(out_path)

    print(f"\nWrote {out_path} (+{written:,} rows this run)")
    return 0


def _dedupe(path) -> None:
    """Collapse the file to one row per (cik, ticker, observed_on).

    Resuming appends, and the live file is re-fetched on every complete
    run, so the same (pair, day) can legitimately be written more than
    once across invocations on one day. The database loader dedupes too,
    but keeping the artifact clean means the row counts printed here mean
    what they say.
    """
    if not path.exists():
        return
    seen: set[tuple[str, str, str]] = set()
    kept: list[list[str]] = []
    with _open_text(path, "r") as f:
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
    with _open_text(path, "w") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(header)
        writer.writerows(kept)


if __name__ == "__main__":
    raise SystemExit(main())
