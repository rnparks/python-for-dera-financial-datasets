"""Thin psycopg3 wrapper.

Small by design: the pipeline issues a handful of DDL and bulk-load
statements per run, so anything beyond a context-managed connection and
file-based SQL runners would be over-engineered.
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import psycopg

from . import config


@contextmanager
def get_conn() -> Iterator[psycopg.Connection]:
    """Open a connection using PG_DSN. Commits on clean exit, rolls back
    on exception, always closes.
    """
    conn = psycopg.connect(config.pg_dsn())
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def run_sql_file(conn: psycopg.Connection, path: Path) -> None:
    """Execute a .sql file as a single statement block.

    psycopg3 happily executes multi-statement strings, including
    ``CREATE FUNCTION ... $$ ... $$`` bodies, so no manual splitting is
    needed.
    """
    sql = path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql)


def run_sql_dir(
    conn: psycopg.Connection,
    directory: Path,
    *,
    skip_prefixes: tuple[str, ...] = (),
) -> list[Path]:
    """Execute every ``*.sql`` file in *directory* in lexical order.

    Files are ordered by name, so numeric prefixes (``010_``, ``020_``)
    drive execution sequence. Files whose name starts with any of
    *skip_prefixes* are announced and skipped; ``build-silver`` uses this
    to leave the security-model DDL alone when there is no filing index
    to rebuild it from. Returns the list of files that were run.
    """
    ran: list[Path] = []
    for path in sorted(directory.glob("*.sql")):
        rel = path.relative_to(config.PROJECT_ROOT)
        if path.name.startswith(skip_prefixes):
            print(f"Skipping {rel}")
            continue
        print(f"Running {rel}")
        run_sql_file(conn, path)
        ran.append(path)
    return ran
