"""Async SEC DERA downloader.

Migrated from populate_data_async.py. The retry loop, semaphore, and
existence-skip behaviour are intentionally preserved; configuration and
the quarter iteration now come from :mod:`dera_pipeline.config` so the
hardcoded year ranges and duplicated year/quarter loops across three
legacy scripts are gone.
"""

from __future__ import annotations

import asyncio
import zipfile
from io import BytesIO
from pathlib import Path
from typing import Iterator

import aiohttp

from . import config


def iter_quarters(
    start: tuple[int, int], end: tuple[int, int]
) -> Iterator[tuple[int, int]]:
    """Yield (year, quarter) pairs inclusive, in chronological order."""
    start_year, start_q = start
    end_year, end_q = end
    if (end_year, end_q) < (start_year, start_q):
        return
    year, quarter = start_year, start_q
    while (year, quarter) <= (end_year, end_q):
        yield year, quarter
        quarter += 1
        if quarter > 4:
            quarter = 1
            year += 1


def quarter_string(year: int, quarter: int) -> str:
    return f"{year}q{quarter}"


def quarter_url(year: int, quarter: int) -> str:
    return f"{config.SEC_BASE_URL}/{quarter_string(year, quarter)}.zip"


def quarter_dir(year: int, quarter: int) -> Path:
    return config.DATA_DIR / quarter_string(year, quarter)


async def fetch_quarter(
    session: aiohttp.ClientSession,
    year: int,
    quarter: int,
    semaphore: asyncio.Semaphore,
) -> Path | None:
    """Download one quarter zip and extract it. Returns the extract path on
    success (including skip), or None on permanent failure.
    """
    extract_to = quarter_dir(year, quarter)
    if extract_to.exists() and any(extract_to.iterdir()):
        print(f"Skipping {extract_to} — already exists.")
        return extract_to

    url = quarter_url(year, quarter)
    headers = {
        "User-Agent": config.sec_user_agent(),
        "Accept-Encoding": "gzip, deflate",
        "Host": "www.sec.gov",
    }
    timeout = aiohttp.ClientTimeout(total=config.REQUEST_TIMEOUT_SECS)

    async with semaphore:
        for attempt in range(1, config.MAX_RETRIES + 1):
            try:
                print(
                    f"Downloading {url} (attempt {attempt}/{config.MAX_RETRIES})"
                )
                async with session.get(url, headers=headers, timeout=timeout) as response:
                    response.raise_for_status()
                    content = await response.read()
                try:
                    with zipfile.ZipFile(BytesIO(content)) as zf:
                        extract_to.mkdir(parents=True, exist_ok=True)
                        zf.extractall(path=extract_to)
                except zipfile.BadZipFile:
                    print(f"BadZipFile for {url}; not retrying.")
                    return None
                print(f"SUCCESS: {extract_to}")
                return extract_to
            except (
                aiohttp.ClientPayloadError,
                aiohttp.ClientError,
                asyncio.TimeoutError,
            ) as exc:
                print(f"Network error on {url}: {exc}")
            except Exception as exc:  # noqa: BLE001 — retry on anything transient
                print(f"Unexpected error on {url}: {exc}")

            if attempt < config.MAX_RETRIES:
                await asyncio.sleep(config.RETRY_DELAY_SECS * attempt)

    print(f"FAILED: {url} after {config.MAX_RETRIES} attempts.")
    return None


async def download_range(
    start: tuple[int, int] = config.DEFAULT_START,
    end: tuple[int, int] = config.DEFAULT_END,
) -> list[Path]:
    """Download every quarter in [start, end]. Returns the list of extract
    directories that are ready on disk (successes + prior skips).
    """
    semaphore = asyncio.Semaphore(config.MAX_CONCURRENT_DOWNLOADS)
    session_timeout = aiohttp.ClientTimeout(total=config.SESSION_TIMEOUT_SECS)

    async with aiohttp.ClientSession(timeout=session_timeout) as session:
        tasks = [
            fetch_quarter(session, year, quarter, semaphore)
            for year, quarter in iter_quarters(start, end)
        ]
        results = await asyncio.gather(*tasks)

    return [p for p in results if p is not None]


def parse_quarter_arg(value: str) -> tuple[int, int]:
    """Parse `2025q3` → (2025, 3). Used by the CLI."""
    value = value.strip().lower()
    if "q" not in value:
        raise ValueError(f"expected format like '2025q3', got {value!r}")
    year_str, quarter_str = value.split("q", 1)
    year = int(year_str)
    quarter = int(quarter_str)
    if quarter not in (1, 2, 3, 4):
        raise ValueError(f"quarter must be 1-4, got {quarter}")
    return year, quarter
