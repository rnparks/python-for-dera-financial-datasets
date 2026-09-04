"""Verify the mechanically checkable claims in every Markdown file.

WHY THIS EXISTS. The documentation drifted about ten commits behind the
code in roughly two days. README.md and docs/architecture.md ended up with
zero mentions of fact_asof, sec_reference or the point-in-time layer at
all; docs/gold_tables.md contradicted itself in one document, telling the
reader on line 73 not to use EXTRACT(YEAR FROM value_date) and on line 122
that peer_stats is bucketed by exactly that. None of it was caught,
because nothing was checking.

WHAT IT CHECKS, AND WHY ONLY THIS. Four classes, chosen because these are
precisely what broke:

    database objects   `sec_gold.peer_stats`   -> pg_class / pg_proc
    file paths         `sql/06_security/...`   -> the filesystem
    CLI commands       `dera build-gold`       -> the argparse parser
    doc cross-links    [x](schema_overview.md) -> the filesystem

WHAT IT DELIBERATELY DOES NOT CHECK. Prose and numbers. A checker that
tries to validate "1,925 of 7,418 members have since delisted" would be
wrong often enough that people learn to ignore its output, and a
verification suite everybody ignores is worse than none -- it converts a
real signal into noise. Numbers are handled by date-stamping instead, so
a reader can see the vintage and judge for themselves.

Escape hatch: put `check-docs:ignore` on a line to skip it. Needed where
a doc quotes a historical name on purpose, e.g. features.md's commit log
referring to peer_zscore_by_sub_industry, which was correct when written
and must stay quoted verbatim.

Run:  uv run dera verify-docs
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from dera_pipeline import config, db

IGNORE_MARKER = "check-docs:ignore"

# `sec_gold.peer_stats`, `sec_reference.universe_at()`, and the
# three-part column form `sec_gold.fact_asof.tradable_from`.
RE_DBOBJ = re.compile(
    r"`(sec_(?:raw|silver|gold|reference)\.[a-z_][a-z0-9_]*(?:\.[a-z_][a-z0-9_]*)?)\(?\)?`")

# Backticked repo-relative paths.
RE_PATH = re.compile(
    r"`((?:sql|tools|dera_pipeline|docs|notebooks|data)/[A-Za-z0-9_./-]+)`")

# A bare numbered SQL basename, e.g. `056_share_class_shares.sql`. This is
# the form docs/gold_tables.md's "Source files" table uses, and it is the
# exact shape that went stale when two files moved to sql/06_security/.
RE_SQL_BASENAME = re.compile(r"`(\d{3}_[a-z0-9_]+\.sql)`")

# `dera build-gold --refresh-only` / `uv run dera verify`
RE_CLI = re.compile(r"`(?:uv run )?dera ([a-z][a-z-]*)((?:\s+--[a-z][a-z-]*)*)")

# Markdown links to local files (not http, not bare anchors).
RE_LINK = re.compile(r"\[[^\]]*\]\((?!https?:|#)([^)#]+)")


def db_inventory(conn) -> set[str]:
    """Every schema-qualified object and column name in the sec_* schemas."""
    names: set[str] = set()
    with conn.cursor() as cur:
        cur.execute("""
            SELECT n.nspname || '.' || c.relname
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname LIKE 'sec\\_%' AND c.relkind IN ('r','m','v','p')
        """)
        names.update(r[0] for r in cur.fetchall())
        cur.execute("""
            SELECT n.nspname || '.' || p.proname
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname LIKE 'sec\\_%'
        """)
        names.update(r[0] for r in cur.fetchall())
        cur.execute("""
            SELECT table_schema || '.' || table_name || '.' || column_name
            FROM information_schema.columns WHERE table_schema LIKE 'sec\\_%'
        """)
        names.update(r[0] for r in cur.fetchall())
    return names


def cli_inventory() -> dict[str, set[str]]:
    """Subcommand -> its option strings, read from the real parser.

    Introspected rather than hardcoded so this cannot drift from cli.py
    the way the docs drifted from the code.
    """
    from dera_pipeline.cli import build_parser
    import argparse

    out: dict[str, set[str]] = {}
    for action in build_parser()._actions:
        if isinstance(action, argparse._SubParsersAction):
            for name, sub in action.choices.items():
                flags = {o for a in sub._actions for o in a.option_strings}
                out[name] = flags
    return out


def check(root: Path, conn) -> list[str]:
    objects = db_inventory(conn)
    commands = cli_inventory()
    sql_basenames = {p.name: p for p in (root / "sql").rglob("*.sql")}
    failures: list[str] = []

    for md in sorted(root.rglob("*.md")):
        if ".venv" in md.parts or ".git" in md.parts:
            continue
        rel = md.relative_to(root)
        for n, line in enumerate(md.read_text(encoding="utf-8").splitlines(), 1):
            if IGNORE_MARKER in line:
                continue
            where = f"{rel}:{n}"

            for name in RE_DBOBJ.findall(line):
                if name not in objects:
                    failures.append(f"{where}  database object does not exist: {name}")

            for path in RE_PATH.findall(line):
                if not (root / path).exists():
                    failures.append(f"{where}  path does not exist: {path}")

            for base in RE_SQL_BASENAME.findall(line):
                if base not in sql_basenames:
                    failures.append(f"{where}  no such SQL file anywhere under sql/: {base}")

            for cmd, flags in RE_CLI.findall(line):
                if cmd not in commands:
                    failures.append(f"{where}  no such dera subcommand: {cmd}")
                else:
                    for flag in flags.split():
                        if flag not in commands[cmd]:
                            failures.append(
                                f"{where}  dera {cmd} has no flag {flag}")

            for target in RE_LINK.findall(line):
                if not (md.parent / target.strip()).exists():
                    failures.append(f"{where}  broken link: {target.strip()}")

    return failures


def main(argv: list[str] | None = None) -> int:
    root = config.PROJECT_ROOT
    with db.get_conn() as conn:
        failures = check(root, conn)

    n_docs = sum(1 for p in root.rglob("*.md")
                 if ".venv" not in p.parts and ".git" not in p.parts)
    if failures:
        for f in failures:
            print(f"FAIL  {f}")
        print(f"\n{len(failures)} stale reference(s) across {n_docs} markdown files.")
        return 1
    print(f"PASS  {n_docs} markdown files, no stale references.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
