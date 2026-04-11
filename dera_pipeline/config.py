"""Single source of truth for pipeline configuration.

All mutable settings are env-driven. Secrets and identity-bearing values
(`SEC_USER_AGENT`, `PG_DSN`) fail loud on access if unset so a
misconfigured run never silently hits SEC with a placeholder email or
writes to the wrong database.
"""

from __future__ import annotations

import os
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent

SEC_BASE_URL = "https://www.sec.gov/files/dera/data/financial-statement-data-sets"

DATA_DIR = Path(os.getenv("DERA_DATA_DIR", PROJECT_ROOT / "data" / "raw"))
REFERENCE_DIR = Path(os.getenv("DERA_REFERENCE_DIR", PROJECT_ROOT / "data" / "reference"))
SQL_DIR = PROJECT_ROOT / "sql"

DEFAULT_START: tuple[int, int] = (2009, 1)
DEFAULT_END: tuple[int, int] = (2025, 4)

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
