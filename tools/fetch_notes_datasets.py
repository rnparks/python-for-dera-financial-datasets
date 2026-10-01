"""Download the SEC Financial Statement and Notes data sets.

WHY. The Financial Statement data sets loaded into sec_data hold the
primary statements only. Footnote disclosures -- defined-benefit pension
assets and obligations, segment revenue, major-customer concentration --
are tagged in the same filings but published separately, in the
Financial Statement and Notes data sets, with each fact's XBRL
dimensions (e.g. RetirementPlanTypeAxis=PensionPlansDefinedBenefitMember,
StatementBusinessSegmentsAxis=<segment>). tools/extract_notes_facts.py
reads them.

SOURCE. The archive list is read from
https://www.sec.gov/data-research/sec-markets-data/financial-statement-notes-data-sets
(quarterly zips 2009q1-2025q2, monthly from 2025_07); each zip is
https://www.sec.gov/files/dera/data/financial-statement-notes-data-sets/<name>.zip.
Cached under data/raw_notes/ (not tracked). A zip already present with
the size the server reports is never re-downloaded; downloads go to a
.partial file renamed on completion. Requests carry SEC_USER_AGENT and
are few and long (one per archive, --workers at a time, default 4), far under the SEC's
10-requests-per-second limit.

Run from the repository root:
    uv run python tools/fetch_notes_datasets.py [--only 2019q1,2024_01] [--workers 4]
"""
from __future__ import annotations

import argparse
import re
import shutil
import sys
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dera_pipeline import config  # noqa: E402

INDEX = "https://www.sec.gov/data-research/sec-markets-data/financial-statement-notes-data-sets"
BASE = "https://www.sec.gov"
CACHE = ROOT / "data" / "raw_notes"


def request(url: str, method: str = "GET") -> urllib.request.Request:
    return urllib.request.Request(url, method=method, headers={"User-Agent": config.sec_user_agent()})


def archives() -> list[str]:
    with urllib.request.urlopen(request(INDEX), timeout=60) as r:
        html = r.read().decode("utf-8", "replace")
    paths = re.findall(r'href="(/files/dera/data/financial-statement-notes-data-sets/[^"]+\.zip)"', html)
    return sorted(set(paths))


def fetch(path: str) -> str:
    name = path.rsplit("/", 1)[1]
    dest = CACHE / name
    with urllib.request.urlopen(request(BASE + path, "HEAD"), timeout=60) as r:
        size = int(r.headers.get("Content-Length", -1))
    if dest.exists() and dest.stat().st_size == size:
        return f"{name}: cached"
    part = dest.with_suffix(".zip.partial")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request(BASE + path), timeout=300) as r, open(part, "wb") as f:
                shutil.copyfileobj(r, f, 1 << 20)
            if part.stat().st_size != size:
                raise OSError(f"size {part.stat().st_size} != {size}")
            part.rename(dest)
            return f"{name}: {size / 1e6:,.0f} MB"
        except OSError as e:
            print(f"{name}: attempt {attempt + 1} failed ({e}); retrying", flush=True)
            time.sleep(30 * (attempt + 1))
    raise RuntimeError(f"{name}: download failed")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="comma-separated archive names, e.g. 2019q1,2024_01")
    ap.add_argument("--workers", type=int, default=4, help="parallel downloads (each one request at a time)")
    args = ap.parse_args()
    CACHE.mkdir(parents=True, exist_ok=True)
    paths = archives()
    if args.only:
        want = {f"{n}_notes.zip" for n in args.only.split(",")}
        paths = [p for p in paths if p.rsplit("/", 1)[1] in want]
    print(f"{len(paths)} archives", flush=True)
    with ThreadPoolExecutor(args.workers) as pool:
        for i, msg in enumerate(pool.map(fetch, paths), 1):
            print(f"({i}/{len(paths)}) {msg}", flush=True)


if __name__ == "__main__":
    main()
