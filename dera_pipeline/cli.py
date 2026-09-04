"""Command-line entry point.

Run via ``uv run dera ...`` once the package is installed; the
``dera`` script is registered in ``pyproject.toml``. Subcommands map
one-to-one to pipeline stages so a full refresh is::

    uv run dera download
    uv run dera init-db
    uv run dera load
    uv run dera build-silver
    uv run dera build-gold

or the shorthand::

    uv run dera run-all
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

from . import config, db, downloader, loader, reference


def _add_range_args(p: argparse.ArgumentParser) -> None:
    p.add_argument(
        "--from",
        dest="from_quarter",
        default=None,
        metavar="YYYYqN",
        help=f"start quarter, e.g. 2009q1 (default: {config.DEFAULT_START[0]}q{config.DEFAULT_START[1]})",
    )
    p.add_argument(
        "--to",
        dest="to_quarter",
        default=None,
        metavar="YYYYqN",
        help=f"end quarter, e.g. 2025q4 (default: {config.DEFAULT_END[0]}q{config.DEFAULT_END[1]})",
    )


def _resolve_range(args: argparse.Namespace) -> tuple[tuple[int, int], tuple[int, int]]:
    start = (
        downloader.parse_quarter_arg(args.from_quarter)
        if args.from_quarter
        else config.DEFAULT_START
    )
    end = (
        downloader.parse_quarter_arg(args.to_quarter)
        if args.to_quarter
        else config.DEFAULT_END
    )
    return start, end


def cmd_download(args: argparse.Namespace) -> int:
    start, end = _resolve_range(args)
    print(f"Downloading {start[0]}q{start[1]} → {end[0]}q{end[1]}")
    paths = asyncio.run(downloader.download_range(start, end))
    print(f"{len(paths)} quarter(s) ready under {config.DATA_DIR}")
    return 0


def cmd_init_db(args: argparse.Namespace) -> int:
    bronze_dir = config.SQL_DIR / "01_bronze"
    with db.get_conn() as conn:
        files = db.run_sql_dir(conn, bronze_dir)
    print(f"Ran {len(files)} bronze DDL file(s).")
    return 0


def cmd_load(args: argparse.Namespace) -> int:
    with db.get_conn() as conn:
        if args.truncate:
            print("Truncating bronze tables...")
            loader.truncate_bronze(conn)
        if args.quarter:
            qdir = config.DATA_DIR / args.quarter
            if not qdir.exists():
                print(f"error: {qdir} does not exist", file=sys.stderr)
                return 1
            loader.load_quarter(conn, qdir)
        else:
            loader.load_all(
                conn, config.DATA_DIR, incremental=not args.full
            )
    return 0


def cmd_build_silver(args: argparse.Namespace) -> int:
    """Build the silver layer.

    Order matters. The trading calendar is created and populated FIRST,
    before `02_silver` runs, because `sub_silver` resolves
    `tradable_from` against it during its own CREATE TABLE AS. The
    calendar lives in `sec_reference` precisely so the
    `DROP SCHEMA sec_silver CASCADE` at the top of the silver build does
    not take it out.
    """
    with db.get_conn() as conn:
        cal_dir = config.SQL_DIR / "00_reference"
        silver_dir = config.SQL_DIR / "02_silver"
        ref_dir = config.SQL_DIR / "04_reference"

        if cal_dir.exists():
            db.run_sql_dir(conn, cal_dir)
            print("Loading trading calendar...")
            reference.load_calendar_only(conn)

        db.run_sql_dir(conn, silver_dir)

        if ref_dir.exists():
            db.run_sql_dir(conn, ref_dir)
            print("Loading reference data...")
            reference.load_all_reference(conn)

        # The company spine is its own stage, deliberately last. It
        # reads universe_sp1500 to decide which ticker is primary for a
        # multi-class company, and that table is only populated by the
        # Python loader above — run_sql_dir executes an entire directory
        # before any of it. Inside 04_reference the spine would see an
        # empty universe and pick the wrong primary every time.
        spine_dir = config.SQL_DIR / "05_spine"
        if spine_dir.exists():
            db.run_sql_dir(conn, spine_dir)

        # Gold's matview joins plan catastrophically against a
        # statistics-less 181M-row table (observed: 9 hours instead of
        # ~1 minute). This was documented but lived in no code path.
        print("Analyzing sec_silver.num_silver (required before gold)...")
        with conn.cursor() as cur:
            cur.execute("ANALYZE sec_silver.num_silver")
            cur.execute("ANALYZE sec_silver.sub_silver")
    return 0


# Gold materialized views, in dependency order. The first three read
# silver directly; peer_stats reads tradable_financials, so it must come
# last. Declared once here so --refresh-only cannot drift out of sync
# with the DDL again.
#
# fact_asof was missing from this tuple until now, which meant
# `build-gold --refresh-only` refreshed the two display matviews and the
# peer scores while leaving stale the one availability-correct table
# that every as_of_* function reads. That is exactly the failure this
# constant exists to prevent.
GOLD_MATVIEWS = (
    "sec_gold.tradable_financials",
    "sec_gold.tradable_financials_pit",
    "sec_gold.fact_asof",
    "sec_gold.peer_stats",
)


def cmd_build_gold(args: argparse.Namespace) -> int:
    """Build (or refresh) the gold layer.

    On first build, ``sql/03_gold/030_tradable_financials.sql`` creates
    the matviews with ``CREATE MATERIALIZED VIEW ... AS SELECT`` which
    populates them immediately — no separate REFRESH is needed. On a
    rebuild against an existing gold schema, pass ``--refresh-only`` to run
    ``REFRESH MATERIALIZED VIEW`` *instead of* re-running the DDL.
    """
    with db.get_conn() as conn:
        gold_dir = config.SQL_DIR / "03_gold"
        if args.refresh_only:
            print("Refreshing materialized views...")
            with conn.cursor() as cur:
                # Order matters: peer_stats is derived from
                # tradable_financials, so it must refresh last.
                for matview in GOLD_MATVIEWS:
                    print(f"  REFRESH {matview}")
                    cur.execute(f"REFRESH MATERIALIZED VIEW {matview}")
        else:
            db.run_sql_dir(conn, gold_dir)
    return 0


def _bronze_quarters_loaded(conn) -> int:
    """How many quarters bronze already holds, 0 if it is not built yet."""
    with conn.cursor() as cur:
        cur.execute("SELECT to_regclass('sec_raw.load_log') IS NOT NULL")
        row = cur.fetchone()
        if not row or not row[0]:
            return 0
        cur.execute("SELECT COUNT(*) FROM sec_raw.load_log")
        return int(cur.fetchone()[0])


def cmd_run_all(args: argparse.Namespace) -> int:
    """Full pipeline, but never silently destroying an existing bronze.

    `cmd_init_db` runs `sql/01_bronze/init_sec.sql`, which opens with
    `DROP SCHEMA IF EXISTS sec_raw CASCADE`. Calling it unconditionally
    meant `dera run-all` against a populated database dropped every
    loaded quarter and re-ingested from scratch, with no prompt and no
    way back short of re-downloading and re-loading everything.

    Bronze is now initialized only when it is empty, or when the caller
    explicitly asks with --reinit-bronze.
    """
    with db.get_conn() as conn:
        loaded = _bronze_quarters_loaded(conn)

    if loaded and not getattr(args, "reinit_bronze", False):
        print(
            f"Bronze already holds {loaded} quarter(s) — skipping init-db so "
            "existing data is preserved.\n"
            "  Pass --reinit-bronze to drop and rebuild sec_raw from scratch."
        )
        steps = (cmd_download, cmd_load, cmd_build_silver, cmd_build_gold)
    else:
        if loaded:
            print(
                f"--reinit-bronze given: DROPPING sec_raw and its "
                f"{loaded} loaded quarter(s)."
            )
        steps = (cmd_download, cmd_init_db, cmd_load, cmd_build_silver,
                 cmd_build_gold)

    for step in steps:
        rc = step(args)
        if rc:
            return rc
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="dera",
        description="SEC DERA Financial Statement Data Sets pipeline.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_dl = sub.add_parser("download", help="download SEC DERA quarterly zips")
    _add_range_args(p_dl)
    p_dl.set_defaults(func=cmd_download)

    p_init = sub.add_parser("init-db", help="create bronze schema and tables")
    p_init.set_defaults(func=cmd_init_db)

    p_load = sub.add_parser("load", help="COPY bronze .txt files into Postgres")
    p_load.add_argument("--quarter", help="load a single quarter (e.g. 2025q4)")
    p_load.add_argument(
        "--full", action="store_true",
        help="re-load even quarters already present in sec_raw.load_log",
    )
    p_load.add_argument(
        "--truncate", action="store_true",
        help="TRUNCATE bronze tables before loading",
    )
    p_load.set_defaults(func=cmd_load)

    p_silver = sub.add_parser("build-silver", help="build the silver layer")
    p_silver.set_defaults(func=cmd_build_silver)

    p_gold = sub.add_parser("build-gold", help="build the gold layer")
    p_gold.add_argument(
        "--refresh-only", action="store_true", default=False,
        help="skip the DDL and only REFRESH existing matviews",
    )
    # README and docs/architecture.md documented --no-refresh for a flag
    # that never existed, so the documented command failed with
    # "unrecognized arguments". Accepted as an explicit no-op alias for
    # the default so those instructions work rather than crash.
    p_gold.add_argument(
        "--no-refresh", dest="refresh_only", action="store_false",
        help="run the full DDL rebuild without REFRESH (this is the default)",
    )
    p_gold.set_defaults(func=cmd_build_gold)

    p_all = sub.add_parser("run-all", help="download + init + load + silver + gold")
    _add_range_args(p_all)
    p_all.add_argument("--truncate", action="store_true")
    p_all.add_argument("--full", action="store_true")
    p_all.add_argument(
        "--reinit-bronze", action="store_true", default=False,
        help="DESTRUCTIVE: drop sec_raw and re-ingest every quarter from "
             "scratch. Without this, run-all preserves an existing bronze.",
    )
    p_all.add_argument("--refresh-only", action="store_true", default=False)
    p_all.add_argument("--quarter", default=None)
    p_all.set_defaults(func=cmd_run_all)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
