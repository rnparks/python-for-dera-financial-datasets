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

from . import config, db, downloader, loader


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
    with db.get_conn() as conn:
        silver_dir = config.SQL_DIR / "02_silver"
        ref_dir = config.SQL_DIR / "04_reference"
        db.run_sql_dir(conn, silver_dir)
        if ref_dir.exists():
            db.run_sql_dir(conn, ref_dir)
    return 0


def cmd_build_gold(args: argparse.Namespace) -> int:
    with db.get_conn() as conn:
        gold_dir = config.SQL_DIR / "03_gold"
        db.run_sql_dir(conn, gold_dir)
        if args.refresh:
            print("Refreshing materialized views...")
            with conn.cursor() as cur:
                cur.execute(
                    "REFRESH MATERIALIZED VIEW sec_gold.tradable_financials"
                )
                cur.execute(
                    "REFRESH MATERIALIZED VIEW sec_gold.tradable_financials_pit"
                )
    return 0


def cmd_run_all(args: argparse.Namespace) -> int:
    for step in (cmd_download, cmd_init_db, cmd_load, cmd_build_silver, cmd_build_gold):
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
        "--no-refresh", dest="refresh", action="store_false", default=True,
        help="skip REFRESH MATERIALIZED VIEW at the end",
    )
    p_gold.set_defaults(func=cmd_build_gold)

    p_all = sub.add_parser("run-all", help="download + init + load + silver + gold")
    _add_range_args(p_all)
    p_all.add_argument("--truncate", action="store_true")
    p_all.add_argument("--full", action="store_true")
    p_all.add_argument("--no-refresh", dest="refresh", action="store_false", default=True)
    p_all.add_argument("--quarter", default=None)
    p_all.set_defaults(func=cmd_run_all)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
