"""Thin psycopg3 wrapper.

Small by design: the pipeline issues a handful of DDL and bulk-load
statements per run, so anything beyond a context-managed connection and
file-based SQL runners would be over-engineered.
"""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
from typing import Iterator

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


def run_sql_dir(conn: psycopg.Connection, directory: Path) -> list[Path]:
    """Execute every ``*.sql`` file in *directory* in lexical order.

    Files are ordered by name, so numeric prefixes (``010_``, ``020_``)
    drive execution sequence. Returns the list of files that were run.
    """
    files = sorted(directory.glob("*.sql"))
    for path in files:
        print(f"Running {path.relative_to(config.PROJECT_ROOT)}")
        run_sql_file(conn, path)
    return files
