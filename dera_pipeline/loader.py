"""Bronze loader.

Streams DERA ``.txt`` files into ``sec_raw.{sub,tag,num,pre}_raw`` via
``COPY FROM STDIN`` using psycopg3's copy API. Replaces the legacy
``load_sec_data()`` plpgsql procedure that shelled out to ``find | head
| cut`` and required ``COPY FROM PROGRAM`` server-side privileges.

Two bugs the legacy procedure hid are fixed here:

1. **Column order** — the legacy schema put ``coreg`` at position 4 of
   ``num_raw`` but the actual SEC ``num.txt`` puts it at position 8.
   Every COPY here uses an explicit column list so the table DDL order
   is independent of the file order.
2. **Schema drift** — on first load of each quarter the file header is
   read and asserted against :data:`EXPECTED_COLUMNS`, so any future
   SEC schema change fails loud instead of silently misaligning.
"""

from __future__ import annotations

from pathlib import Path

import psycopg

# Column definitions are the authoritative order of the .txt file
# headers as published by SEC. Verified against
# examples/data/2025q3/{sub,tag,num,pre}.txt.
EXPECTED_COLUMNS: dict[str, tuple[str, ...]] = {
    "sub.txt": (
        "adsh", "cik", "name", "sic", "countryba", "stprba", "cityba",
        "zipba", "bas1", "bas2", "baph", "countryma", "stprma", "cityma",
        "zipma", "mas1", "mas2", "countryinc", "stprinc", "ein", "former",
        "changed", "afs", "wksi", "fye", "form", "period", "fy", "fp",
        "filed", "accepted", "prevrpt", "detail", "instance", "nciks",
        "aciks",
    ),
    "tag.txt": (
        "tag", "version", "custom", "abstract", "datatype", "iord", "crdr",
        "tlabel", "doc",
    ),
    "num.txt": (
        "adsh", "tag", "version", "ddate", "qtrs", "uom", "segments",
        "coreg", "value", "footnote",
    ),
    "pre.txt": (
        "adsh", "report", "line", "stmt", "inpth", "rfile", "tag",
        "version", "plabel", "negating",
    ),
}

TARGET_TABLES: dict[str, str] = {
    "sub.txt": "sec_raw.sub_raw",
    "tag.txt": "sec_raw.tag_raw",
    "num.txt": "sec_raw.num_raw",
    "pre.txt": "sec_raw.pre_raw",
}

# Chunk size for streamed reads during COPY. 1 MiB is a sensible default.
_CHUNK_BYTES = 1 << 20

# SEC DERA files use standard CSV quoting: fields that contain embedded
# tabs (e.g. num.txt's `segments` column when it holds a multi-segment
# axis description with commas and tabs) are wrapped in double quotes.
# We use default QUOTE and ESCAPE so those rows parse correctly.
#
# The legacy load_sec_data procedure used QUOTE=E'\x01' to disable
# quoting entirely, then compensated with `cut -f 1-N` shelling — which
# silently truncated everything after the first embedded tab and lost
# most of the segments value. Using real CSV quoting here preserves the
# full field.
_COPY_OPTIONS = (
    "FORMAT CSV, HEADER true, DELIMITER E'\\t', NULL '', "
    "ENCODING 'LATIN1'"
)


def _verify_header(path: Path, expected: tuple[str, ...]) -> None:
    with open(path, "r", encoding="latin-1") as f:
        header_line = f.readline().rstrip("\n").rstrip("\r")
    actual = tuple(header_line.split("\t"))
    if actual != expected:
        raise ValueError(
            f"Header mismatch for {path.name}:\n"
            f"  expected: {expected}\n"
            f"  actual:   {actual}"
        )


def _copy_file(
    conn: psycopg.Connection,
    path: Path,
    table: str,
    columns: tuple[str, ...],
) -> int:
    """Stream *path* into *table* via COPY FROM STDIN. Returns row count."""
    col_list = ", ".join(columns)
    sql = f"COPY {table} ({col_list}) FROM STDIN WITH ({_COPY_OPTIONS})"
    with open(path, "rb") as fh, conn.cursor() as cur:
        with cur.copy(sql) as cp:
            while chunk := fh.read(_CHUNK_BYTES):
                cp.write(chunk)
        return cur.rowcount if cur.rowcount is not None else 0


class QuarterAlreadyLoaded(RuntimeError):
    """Raised when a quarter in ``sec_raw.load_log`` would be loaded again."""


def load_quarter(
    conn: psycopg.Connection, quarter_dir: Path, *, force: bool = False
) -> dict[str, int]:
    """Load one quarter directory into the bronze layer.

    Returns a ``{filename: row_count}`` map. Raises ``FileNotFoundError``
    if any of the four expected files is missing; raises ``ValueError``
    if any header has drifted from the expected schema.

    Refuses a quarter that ``sec_raw.load_log`` already lists unless
    *force* is set. Bronze has no quarter column, so a second COPY of the
    same quarter cannot be told apart from the first and simply doubles
    every row for it; the only way back is a full truncate and reload.
    Nothing in the pipeline needs to load a quarter twice, so the guard
    costs nothing and the footgun goes away.
    """
    _ensure_load_log(conn)
    if not force and quarter_dir.name in loaded_quarters(conn):
        raise QuarterAlreadyLoaded(
            f"{quarter_dir.name} is already in sec_raw.load_log. Loading it "
            "again would duplicate every bronze row for that quarter, and "
            "bronze has no quarter column to replace by. Use "
            "`dera load --truncate --full` to reload everything, or "
            "`--force` if you have removed the rows yourself."
        )
    counts: dict[str, int] = {}
    for filename, expected in EXPECTED_COLUMNS.items():
        path = quarter_dir / filename
        if not path.exists():
            raise FileNotFoundError(f"{path} not found")
        _verify_header(path, expected)
        table = TARGET_TABLES[filename]
        counts[filename] = _copy_file(conn, path, table, expected)
        print(f"  {filename:<10} → {table:<20} {counts[filename]:>10,} rows")
    _record_loaded(conn, quarter_dir.name, counts)
    return counts


def load_all(
    conn: psycopg.Connection,
    data_dir: Path,
    *,
    incremental: bool = True,
) -> dict[str, dict[str, int]]:
    """Load every ``<year>q<n>/`` subdirectory of *data_dir*.

    With ``incremental=True`` (default), quarters already listed in
    ``sec_raw.load_log`` are skipped. Each quarter is committed as its
    own transaction so progress is visible from other sessions via
    ``sec_raw.load_log`` and a mid-run failure keeps everything loaded
    up to the last successful quarter.

    ``incremental=False`` re-loads every quarter and therefore requires
    the bronze tables to have been truncated first; the CLI enforces
    ``--truncate`` alongside ``--full`` for that reason. Without the
    truncate, every quarter already present would be doubled.
    """
    _ensure_load_log(conn)
    conn.commit()  # persist load_log creation before the per-quarter loop
    already = loaded_quarters(conn) if incremental else set()
    if not incremental and already:
        raise QuarterAlreadyLoaded(
            f"{len(already)} quarter(s) are still in sec_raw.load_log; a "
            "full reload must start from truncated bronze tables "
            "(`dera load --truncate --full`)."
        )
    quarter_dirs = sorted(
        p for p in data_dir.iterdir()
        if p.is_dir() and _looks_like_quarter(p.name)
    )
    result: dict[str, dict[str, int]] = {}
    for qdir in quarter_dirs:
        if qdir.name in already:
            print(f"Skipping {qdir.name} — already loaded.")
            continue
        print(f"Loading {qdir.name}")
        try:
            result[qdir.name] = load_quarter(conn, qdir, force=not incremental)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
    return result


def truncate_bronze(conn: psycopg.Connection) -> None:
    """Wipe the bronze layer and the load log. Use with caution."""
    with conn.cursor() as cur:
        cur.execute(
            "TRUNCATE TABLE sec_raw.sub_raw, sec_raw.tag_raw, "
            "sec_raw.num_raw, sec_raw.pre_raw"
        )
        cur.execute("TRUNCATE TABLE sec_raw.load_log")


def loaded_quarters(conn: psycopg.Connection) -> set[str]:
    _ensure_load_log(conn)
    with conn.cursor() as cur:
        cur.execute("SELECT quarter FROM sec_raw.load_log")
        return {row[0] for row in cur.fetchall()}


def _ensure_load_log(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute(
            "CREATE TABLE IF NOT EXISTS sec_raw.load_log ("
            "  quarter TEXT PRIMARY KEY,"
            "  loaded_at TIMESTAMPTZ NOT NULL DEFAULT now(),"
            "  sub_rows BIGINT, tag_rows BIGINT,"
            "  num_rows BIGINT, pre_rows BIGINT"
            ")"
        )


def _record_loaded(
    conn: psycopg.Connection, quarter: str, counts: dict[str, int]
) -> None:
    _ensure_load_log(conn)
    with conn.cursor() as cur:
        cur.execute(
            "INSERT INTO sec_raw.load_log "
            "(quarter, sub_rows, tag_rows, num_rows, pre_rows) "
            "VALUES (%s, %s, %s, %s, %s) "
            "ON CONFLICT (quarter) DO UPDATE SET "
            "  loaded_at = now(),"
            "  sub_rows = EXCLUDED.sub_rows,"
            "  tag_rows = EXCLUDED.tag_rows,"
            "  num_rows = EXCLUDED.num_rows,"
            "  pre_rows = EXCLUDED.pre_rows",
            (
                quarter,
                counts.get("sub.txt"),
                counts.get("tag.txt"),
                counts.get("num.txt"),
                counts.get("pre.txt"),
            ),
        )


def _looks_like_quarter(name: str) -> bool:
    lower = name.lower()
    if len(lower) != 6 or lower[4] != "q":
        return False
    try:
        int(lower[:4])
        return lower[5] in "1234"
    except ValueError:
        return False
