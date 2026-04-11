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


def _find_column_or_none(columns: list[str], *needles: str) -> str | None:
    try:
        return _find_column(columns, *needles)
    except KeyError:
        return None


def scrape_index(name: str, url: str, headers: dict[str, str]) -> pd.DataFrame:
    print(f"Fetching {name}...")
    request = Request(url, headers=headers)
    with urlopen(request, timeout=60) as response:
        html = response.read().decode("utf-8")
    tables = pd.read_html(StringIO(html))
    df = tables[0]
    cols = list(df.columns)
    ticker_col     = _find_column(cols, "Symbol", "Ticker")
    name_col       = _find_column(cols, "Security", "Company")
    sector_col     = _find_column_or_none(cols, "GICS Sector")
    sub_ind_col    = _find_column_or_none(cols, "GICS Sub")
    keep_cols = [ticker_col, name_col]
    rename = {ticker_col: "ticker", name_col: "name"}
    if sector_col:
        keep_cols.append(sector_col)
        rename[sector_col] = "gics_sector"
    if sub_ind_col:
        keep_cols.append(sub_ind_col)
        rename[sub_ind_col] = "gics_sub_industry"
    subset = df[keep_cols].copy().rename(columns=rename)
    if "gics_sector" not in subset.columns:
        subset["gics_sector"] = None
    if "gics_sub_industry" not in subset.columns:
        subset["gics_sub_industry"] = None
    subset["index_name"] = name
    subset = subset[["ticker", "name", "index_name", "gics_sector", "gics_sub_industry"]]
    missing_sector = subset["gics_sector"].isna().sum()
    print(
        f"  {name}: {len(subset)} companies "
        f"({len(subset) - missing_sector} with GICS)"
    )
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
