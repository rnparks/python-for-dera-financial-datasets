"""Command-line entry point.

Run via ``uv run dera ...`` once the package is installed; the
``dera`` script is registered in ``pyproject.toml``.

Eleven subcommands. The medallion pipeline, in order::

    uv run dera download
    uv run dera init-db
    uv run dera load
    uv run dera build-silver
    uv run dera build-gold

or the shorthand ``uv run dera run-all``.

The security lifecycle model, an additive second path::

    uv run dera fetch-filing-index      # EDGAR bulk archive, ~1.5 GB
    uv run dera build-security-model

and the iteration loop for everything downstream of the crosswalk::

    uv run dera rebuild-reference       # spine -> security model -> gold

which exists because rebuilding the company spine drops every gold
matview (they depend on ``sec_reference.company``), so a crosswalk change
always means those three stages in that order.

``build-silver`` also builds the security model when the archive is
present. When it is not, the stage is skipped with a message AND the
existing security tables are left untouched: the DDL that would drop
them (``sql/00_reference/040_*`` and ``041_*``) is skipped too, so a
silver rebuild without the archive cannot empty a model it will not
refill.

Verification::

    uv run dera verify        # 50 data-correctness checks
    uv run dera verify-docs   # documentation against code and database
"""

from __future__ import annotations

import argparse
import asyncio
import subprocess
import sys

from . import config, db, downloader, filings, loader, reference


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
    # Bronze has no quarter column, so a repeated COPY of a quarter is
    # indistinguishable from the first and doubles its rows. --full
    # therefore requires --truncate, and --quarter refuses a quarter
    # already in load_log unless --force says the rows are gone.
    if args.full and not args.truncate:
        print("error: --full re-loads every quarter and must be combined "
              "with --truncate, otherwise every quarter already in bronze "
              "is duplicated.", file=sys.stderr)
        return 2
    with db.get_conn() as conn:
        if args.truncate:
            print("Truncating bronze tables...")
            loader.truncate_bronze(conn)
        if args.quarter:
            qdir = config.DATA_DIR / args.quarter
            if not qdir.exists():
                print(f"error: {qdir} does not exist", file=sys.stderr)
                return 1
            try:
                loader.load_quarter(
                    conn, qdir, force=getattr(args, "force", False))
            except loader.QuarterAlreadyLoaded as exc:
                print(f"error: {exc}", file=sys.stderr)
                return 2
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
        have_archive = filings.BULK_PATH.exists()

        if cal_dir.exists():
            # 040_security_model.sql and 041_security_derive.sql DROP the
            # security tables and their staging. Running them without the
            # archive to refill from left the model empty while the log
            # said "Skipping security model", which reads as "preserved".
            # Without the archive they are skipped, so the model that
            # exists survives the silver rebuild (stale, but present, and
            # `dera build-security-model` refreshes it in minutes).
            db.run_sql_dir(
                conn, cal_dir,
                skip_prefixes=() if have_archive else ("040_", "041_"))
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

        # Security lifecycle. Its staging tables are created by
        # 00_reference above and filled here, so the derivation in
        # 06_security must run after this call rather than alongside the
        # rest of the DDL. Skipped with a message when the archive is
        # absent: a missing optional input should not destroy a 39-minute
        # silver build that is otherwise complete.
        sec_dir = config.SQL_DIR / "06_security"
        if sec_dir.exists():
            if have_archive:
                print("Loading EDGAR filing index...")
                stats = filings.load_security_events(conn)
                print(f"  {stats['events']:,} events, {stats['names']:,} names "
                      f"across {stats['ciks_requested']:,} CIKs")
                db.run_sql_dir(conn, sec_dir)
            else:
                print(f"Skipping security model: {filings.BULK_PATH} not found "
                      "(run `dera fetch-filing-index`). Existing security "
                      "tables were preserved, not rebuilt; their eligibility "
                      "intervals may lag the new silver until "
                      "`dera build-security-model` runs.")

        # Gold's matview joins plan catastrophically against a
        # statistics-less 181M-row table (observed: 9 hours instead of
        # ~1 minute). This was documented but lived in no code path.
        print("Analyzing sec_silver.num_silver (required before gold)...")
        with conn.cursor() as cur:
            cur.execute("ANALYZE sec_silver.num_silver")
            cur.execute("ANALYZE sec_silver.sub_silver")
    return 0


# Gold materialized views, in dependency order. The first four read
# silver directly; only peer_stats reads another matview
# (tradable_financials), so it must come last. Declared once here so --refresh-only cannot drift out of sync
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
    "sec_gold.share_class_shares",
    "sec_gold.peer_stats",
)


def cmd_build_gold(args: argparse.Namespace) -> int:
    """Build (or refresh) the gold layer.

    On first build the ``sql/03_gold`` DDL creates the five matviews
    across four files (030, 035, 056, 080) with
    ``CREATE MATERIALIZED VIEW ... AS SELECT``, which populates them
    immediately — no separate REFRESH is needed. On a
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


def cmd_fetch_filing_index(args: argparse.Namespace) -> int:
    """Download the EDGAR bulk submissions archive.

    One request instead of roughly 25,000 per-CIK API calls, and a single
    reproducible artifact. ~1.5 GB, gitignored.
    """
    import urllib.request

    filings.BULK_PATH.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {filings.BULK_URL}")
    req = urllib.request.Request(
        filings.BULK_URL, headers={"User-Agent": config.sec_user_agent()})
    with urllib.request.urlopen(req, timeout=1800) as resp, \
            open(filings.BULK_PATH, "wb") as fh:
        while chunk := resp.read(1 << 20):
            fh.write(chunk)
    size_mb = filings.BULK_PATH.stat().st_size / (1 << 20)
    print(f"Wrote {filings.BULK_PATH} ({size_mb:,.0f} MB)")
    return 0


def _build_security_model(conn) -> None:
    """DDL, event ingest and derivation for the security model, in order."""
    db.run_sql_file(conn, config.SQL_DIR / "00_reference" / "040_security_model.sql")
    db.run_sql_file(conn, config.SQL_DIR / "00_reference" / "041_security_derive.sql")
    print("Loading EDGAR filing index...")
    stats = filings.load_security_events(conn)
    print(f"  {stats['events']:,} events, {stats['names']:,} names "
          f"across {stats['ciks_requested']:,} CIKs")
    db.run_sql_dir(conn, config.SQL_DIR / "06_security")


def cmd_build_security_model(args: argparse.Namespace) -> int:
    """Rebuild the security lifecycle model without a full silver rebuild.

    The iteration loop for this work: the derivation rules change far
    more often than the 185M-row silver layer does.
    """
    with db.get_conn() as conn:
        _build_security_model(conn)
    return 0


def cmd_rebuild_reference(args: argparse.Namespace) -> int:
    """Rebuild everything downstream of the ticker crosswalk.

    Three stages, three transactions, in the only order that works:

    1. the company spine (``sql/05_spine``), which reads
       ``ticker_observation`` and DROPs ``sec_reference.company`` with
       CASCADE -- taking every gold matview with it;
    2. the security model, whose listings read the spine;
    3. gold, which reads both.

    A crosswalk change used to mean remembering that sequence and
    running the middle of it by hand with ``psql -f``. Each stage commits
    on its own so a failure in gold does not force the spine to rebuild
    again.
    """
    with db.get_conn() as conn:
        print("Stage 1/3: company spine (drops gold matviews)...")
        db.run_sql_dir(conn, config.SQL_DIR / "05_spine")
    with db.get_conn() as conn:
        print("Stage 2/3: security model...")
        if not filings.BULK_PATH.exists():
            print(f"error: {filings.BULK_PATH} not found; run "
                  "`dera fetch-filing-index` first.", file=sys.stderr)
            return 1
        _build_security_model(conn)
    print("Stage 3/3: gold...")
    return cmd_build_gold(argparse.Namespace(refresh_only=False))


def cmd_verify(args: argparse.Namespace) -> int:
    r"""Run the point-in-time verification suite.

    `tools/verify_pit.sql` had 15 passing checks at the time and was
    invoked from nothing: no test runner, no CI, no CLI path. It now
    holds 48. A correctness suite
    nobody runs is documentation, not a guard. This gives it a command.

    It shells out to psql rather than going through psycopg because the
    file uses \echo and \pset meta-commands, which psycopg cannot
    execute. Rewriting them to avoid the dependency would cost the
    readable section headers that make a failure legible.
    """
    suite = config.PROJECT_ROOT / "tools" / "verify_pit.sql"
    if not suite.exists():
        print(f"error: {suite} not found", file=sys.stderr)
        return 1

    dsn = config.pg_dsn()
    print(f"Running {suite.name} ...\n")
    proc = subprocess.run(
        ["psql", dsn, "-v", "ON_ERROR_STOP=1", "-f", str(suite)],
        capture_output=True, text=True,
    )
    sys.stdout.write(proc.stdout)
    if proc.stderr.strip():
        sys.stderr.write(proc.stderr)

    if proc.returncode != 0:
        print("\nSuite did not complete.", file=sys.stderr)
        return proc.returncode

    # Each check prints PASS or FAIL in its status column, so the exit
    # code can reflect the result rather than merely whether psql ran.
    failures = sum(
        1 for line in proc.stdout.splitlines()
        if line.strip().startswith("FAIL") or " FAIL " in line
    )
    passes = sum(
        1 for line in proc.stdout.splitlines()
        if line.strip().startswith("PASS") or " PASS " in line
    )
    print(f"\n{passes} passed, {failures} failed.")
    return 1 if failures else 0


def cmd_verify_docs(args: argparse.Namespace) -> int:
    """Verify the mechanically checkable claims in the Markdown files.

    Complements `dera verify`, which checks the data. This checks the
    documentation against the code and database: object names, file
    paths, CLI commands and cross-links. See tools/check_docs.py for what
    it deliberately does not check and why.
    """
    sys.path.insert(0, str(config.PROJECT_ROOT / "tools"))
    import check_docs
    return check_docs.main()


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
        help="TRUNCATE bronze tables before loading (required with --full)",
    )
    p_load.add_argument(
        "--force", action="store_true",
        help="with --quarter: load even if the quarter is already in "
             "sec_raw.load_log (duplicates rows unless you removed them)",
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

    p_fidx = sub.add_parser(
        "fetch-filing-index",
        help="download the EDGAR bulk submissions archive (~1.5 GB)")
    p_fidx.set_defaults(func=cmd_fetch_filing_index)

    p_secm = sub.add_parser(
        "build-security-model",
        help="rebuild the security lifecycle model from the filing index")
    p_secm.set_defaults(func=cmd_build_security_model)

    p_rref = sub.add_parser(
        "rebuild-reference",
        help="rebuild spine, security model and gold after a crosswalk change")
    p_rref.set_defaults(func=cmd_rebuild_reference)

    p_verify = sub.add_parser(
        "verify", help="run the point-in-time verification suite")
    p_verify.set_defaults(func=cmd_verify)

    p_vdocs = sub.add_parser(
        "verify-docs",
        help="check docs for stale object names, paths, commands and links")
    p_vdocs.set_defaults(func=cmd_verify_docs)

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
    p_all.add_argument("--force", action="store_true", default=False)
    p_all.set_defaults(func=cmd_run_all)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
