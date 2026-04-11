"""Scrape the S&P 500, 400, and 600 constituent lists from Wikipedia
and write a combined sp1500_universe.csv.

Rewritten from the legacy get_sp1500.py. Uses the project
SEC_USER_AGENT from dera_pipeline.config so the placeholder email in
the old script can't sneak out, and the output path defaults to
data/reference/sp1500_universe.csv where dera_pipeline.reference
looks for it.

Usage::

    uv run python tools/fetch_sp1500.py
    uv run python tools/fetch_sp1500.py --output /tmp/sp1500.csv
"""

from __future__ import annotations

import argparse
import sys
from io import StringIO
from pathlib import Path
from urllib.request import Request, urlopen

import pandas as pd

from dera_pipeline import config

INDEX_URLS = {
    "SP500": "https://en.wikipedia.org/wiki/List_of_S%26P_500_companies",
    "SP400": "https://en.wikipedia.org/wiki/List_of_S%26P_400_companies",
    "SP600": "https://en.wikipedia.org/wiki/List_of_S%26P_600_companies",
}


def _find_column(columns: list[str], *needles: str) -> str:
    for col in columns:
        if any(n in col for n in needles):
            return col
    raise KeyError(f"no column matching {needles!r} in {columns!r}")


def scrape_index(name: str, url: str, headers: dict[str, str]) -> pd.DataFrame:
    print(f"Fetching {name}...")
    request = Request(url, headers=headers)
    with urlopen(request, timeout=60) as response:
        html = response.read().decode("utf-8")
    tables = pd.read_html(StringIO(html))
    df = tables[0]
    ticker_col = _find_column(list(df.columns), "Symbol", "Ticker")
    name_col = _find_column(list(df.columns), "Security", "Company")
    subset = df[[ticker_col, name_col]].copy()
    subset.columns = ["ticker", "name"]
    subset["index_name"] = name
    print(f"  {name}: {len(subset)} companies")
    return subset


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--output",
        type=Path,
        default=config.REFERENCE_DIR / "sp1500_universe.csv",
        help="output CSV path (default: data/reference/sp1500_universe.csv)",
    )
    args = parser.parse_args(argv)

    headers = {"User-Agent": config.sec_user_agent()}
    frames: list[pd.DataFrame] = []
    for index_name, url in INDEX_URLS.items():
        try:
            frames.append(scrape_index(index_name, url, headers))
        except Exception as exc:  # noqa: BLE001 — partial result is still useful
            print(f"Error scraping {index_name}: {exc}", file=sys.stderr)

    if not frames:
        print("No tickers found — all scrapes failed.", file=sys.stderr)
        return 1

    combined = pd.concat(frames, ignore_index=True)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    combined.to_csv(args.output, index=False)
    print(f"Wrote {len(combined)} tickers to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
