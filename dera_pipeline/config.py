"""Single source of truth for pipeline configuration.

All mutable settings are env-driven. Secrets and identity-bearing values
(`SEC_USER_AGENT`, `PG_DSN`) fail loud on access if unset so a
misconfigured run never silently hits SEC with a placeholder email or
writes to the wrong database.
"""

from __future__ import annotations

import os
from datetime import date
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent


def _load_dotenv(path: Path) -> None:
    """Populate os.environ from a .env file if one exists.

    `.env.example` has always told users "the dera CLI reads these at
    runtime", but nothing actually read the file — the settings below
    only ever consulted os.environ, so a correctly filled-in .env was
    silently ignored and every command still failed on a missing
    SEC_USER_AGENT. This closes that gap.

    A real environment variable always wins, so `SEC_USER_AGENT=... uv
    run dera ...` still overrides the file. Parsing is deliberately
    minimal (KEY=VALUE, `#` comments, optional surrounding quotes)
    rather than pulling in python-dotenv for fifteen lines of work.
    """
    if not path.exists():
        return
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return
    for raw in content.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_dotenv(PROJECT_ROOT / ".env")

SEC_BASE_URL = "https://www.sec.gov/files/dera/data/financial-statement-data-sets"

DATA_DIR = Path(os.getenv("DERA_DATA_DIR", PROJECT_ROOT / "data" / "raw"))
REFERENCE_DIR = Path(os.getenv("DERA_REFERENCE_DIR", PROJECT_ROOT / "data" / "reference"))
SQL_DIR = PROJECT_ROOT / "sql"

DEFAULT_START: tuple[int, int] = (2009, 1)


def last_completed_quarter(today: date | None = None) -> tuple[int, int]:
    """The most recent calendar quarter that has fully elapsed.

    SEC publishes a quarter's dataset a few days after the quarter ends,
    so this is the newest quarter worth asking for. It replaces a
    hardcoded ``(2026, 2)`` that had to be bumped by hand every three
    months and was already a quarter stale once. A quarter that is not
    published yet comes back as a 404, which the downloader reports once
    and skips.
    """
    from datetime import date

    d = today or date.today()
    quarter = (d.month - 1) // 3 + 1
    if quarter == 1:
        return d.year - 1, 4
    return d.year, quarter - 1


DEFAULT_END: tuple[int, int] = last_completed_quarter()

MAX_CONCURRENT_DOWNLOADS = 5
MAX_RETRIES = 3
RETRY_DELAY_SECS = 2
REQUEST_TIMEOUT_SECS = 300
SESSION_TIMEOUT_SECS = 600


def sec_user_agent() -> str:
    value = os.environ.get("SEC_USER_AGENT")
    if not value:
        raise RuntimeError(
            "SEC_USER_AGENT is not set. SEC requires a descriptive user "
            "agent with a contact email; export SEC_USER_AGENT before "
            "running any download command."
        )
    return value


def pg_dsn() -> str:
    value = os.environ.get("PG_DSN")
    if not value:
        raise RuntimeError(
            "PG_DSN is not set. Example: "
            "postgresql://user:password@localhost:5432/dera"
        )
    return value
