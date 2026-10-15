"""The Goyal-Welch predictors, from Amit Goyal's data page.

The aggregate-market variables of Welch and Goyal (2008) and Goyal, Welch
and Zafirov (2024), in ``macro.gw_observation`` (DDL in
``sql/08_macro/010_goyal_welch.sql``), loaded by ``uv run dera load-macro``.
Not SEC data and not about any one company: its own schema.

What it fetches
---------------
Two workbooks Goyal links from https://sites.google.com/view/agoyal145:
the combined file (the GW 2008 and GWZ 2024 data in one: Monthly,
Quarterly and Annual sheets, 56 columns, a ReadMe) and the updated 2008
file, which alone carries the quarterly 3-month sums D3 and E3. Both land
in ``data/external/goyal_welch/`` (gitignored) with their SHA-256 and the
workbook's own last-modified stamp, the vintage, recorded in
``macro.gw_load``.

What it stores
--------------
Every non-empty cell as published. The combined workbook is the primary
source; from the 2008 workbook only what the combined one lacks. Every
cell the two share must agree, or nothing is loaded: on 2026-10-15 they
agreed on all of them. Every variable needs a row in
``data/reference/goyal_welch_variables.csv`` first (the foreign key
enforces it), because that row decides whether and from when a
point-in-time reader may use it.

Never ranked across stocks
--------------------------
A macro value is one number per month that every stock shares. The
accessors return one row per month, and ``gkx_covariates`` below takes
the macro state and the ranked characteristics as separate inputs, so
the state reaches a model raw (or z-scored over time) and never through a
cross-sectional ranker.

Network use is confined to ``fetch``; everything else is pure or
database-only, so the tests cover the logic without a download.
"""

from __future__ import annotations

import csv
import datetime as dt
import hashlib
import math
import re
import sys
import urllib.request
import zipfile
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path

import psycopg

from . import config

# The Google Drive file ids behind the links on Goyal's page. The
# usercontent endpoint returns the original bytes (the same SHA-256 as the
# Sheets export, checked 2026-10-15); `confirm=t` skips the interstitial
# Drive shows for files it does not virus-scan.
WORKBOOKS: dict[str, tuple[str, str]] = {
    "gwz_combined": ("17mw_IpaiLFDrGnrPRQ2o1ugV5nJsZuD1", "goyal_welch_zafirov_combined.xlsx"),
    "gw2008": ("1qwpl2R_DNujpU5YUkk8lacP1tTeMb9iJ", "goyal_welch_2008_updated.xlsx"),
}
DOWNLOAD_URL = "https://drive.usercontent.google.com/download?id={id}&export=download&confirm=t"
EXTERNAL_DIR = config.PROJECT_ROOT / "data" / "external" / "goyal_welch"
CATALOGUE = config.REFERENCE_DIR / "goyal_welch_variables.csv"

SHEETS = {"Monthly": "M", "Quarterly": "Q", "Annual": "A"}
TIMINGS = ("market", "release_lag", "quarter_end", "interpolated", "full_sample", "unverified")
USABLE = ("market", "release_lag", "quarter_end")

# The 2008 workbook spells six series differently; the combined
# workbook's names are the ones stored.
GW2008_RENAMES = {
    "Index": "price", "D12": "d12", "E12": "e12",
    "CRSP_SPvw": "ret", "CRSP_SPvwx": "retx", "ik": "i/k",
}

# Two workbooks agree on a shared cell when they differ by no more than
# this, relative. They were equal to the last bit on 2026-10-15; the
# tolerance only absorbs a re-save that prints a digit differently.
AGREEMENT_RTOL = 1e-12

Key = tuple[str, str, dt.date]  # (variable, frequency, period_end)


@dataclass(frozen=True)
class Variable:
    variable: str
    description: str
    native_frequency: str
    timing: str
    lag_months: int | None
    source_note: str


# ----------------------------------------------------------------------
# Pure functions
# ----------------------------------------------------------------------

def period_end(code: int, frequency: str) -> dt.date:
    """The last calendar day of the period a sheet's first column names:
    ``yyyymm`` on the Monthly sheet, ``yyyyq`` on the Quarterly, ``yyyy``
    on the Annual."""
    code = int(code)
    if frequency == "M":
        year, month = divmod(code, 100)
        if not 1 <= month <= 12:
            raise ValueError(f"not a yyyymm month: {code}")
    elif frequency == "Q":
        year, quarter = divmod(code, 10)
        if not 1 <= quarter <= 4:
            raise ValueError(f"not a yyyyq quarter: {code}")
        month = quarter * 3
    elif frequency == "A":
        year, month = code, 12
    else:
        raise ValueError(f"unknown frequency: {frequency!r}")
    if not 1800 <= year <= 2200:
        raise ValueError(f"implausible year in period code {code}")
    first_of_next = dt.date(year + (month == 12), month % 12 + 1, 1)
    return first_of_next - dt.timedelta(days=1)


def _number(value) -> float | None:
    """A cell as a finite float, or None: the workbooks write a missing
    value as an empty cell or the text 'NaN'."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        x = float(value)
    elif isinstance(value, str):
        try:
            x = float(value.strip())
        except ValueError:
            return None
    else:
        return None
    return x if math.isfinite(x) else None


def parse_sheet(
    rows: Iterable[Sequence], frequency: str, renames: Mapping[str, str] | None = None,
) -> dict[Key, float]:
    """The non-empty cells of one sheet: the header row names the
    variables (renamed through *renames*), the first column the period."""
    renames = renames or {}
    it = iter(rows)
    header = next(it)
    names = [None if h is None else renames.get(str(h).strip(), str(h).strip())
             for h in header[1:]]
    out: dict[Key, float] = {}
    for row in it:
        if not row or row[0] is None or str(row[0]).strip() == "":
            continue
        end = period_end(int(row[0]), frequency)
        for name, cell in zip(names, row[1:]):
            if not name:
                continue
            x = _number(cell)
            if x is not None:
                out[(name, frequency, end)] = x
    return out


def parse_workbook(
    sheets: Mapping[str, Sequence[Sequence]], renames: Mapping[str, str] | None = None,
) -> dict[Key, float]:
    """Every data sheet of a workbook (Monthly, Quarterly, Annual); any
    other sheet, the ReadMe among them, is ignored."""
    out: dict[Key, float] = {}
    for title, frequency in SHEETS.items():
        if title in sheets:
            out.update(parse_sheet(sheets[title], frequency, renames))
    return out


def disagreements(
    a: Mapping[Key, float], b: Mapping[Key, float], rtol: float = AGREEMENT_RTOL,
) -> list[tuple[Key, float, float]]:
    """The cells both workbooks carry with different values."""
    out = []
    for key in a.keys() & b.keys():
        x, y = a[key], b[key]
        if abs(x - y) > rtol * max(1.0, abs(x), abs(y)):
            out.append((key, x, y))
    return sorted(out)


def merge(
    primary: Mapping[Key, float], secondary: Mapping[Key, float],
    primary_name: str = "gwz_combined", secondary_name: str = "gw2008",
) -> dict[Key, tuple[float, str]]:
    """The primary workbook's cells, then the secondary's where the primary
    has none, each with the workbook it came from."""
    out = {k: (v, primary_name) for k, v in primary.items()}
    for k, v in secondary.items():
        out.setdefault(k, (v, secondary_name))
    return out


def read_catalogue(path: Path = CATALOGUE) -> list[Variable]:
    """The variable catalogue, validated: a known timing class, a lag
    exactly when the class is usable, a cited source on every row. The
    table's CHECKs say the same; this fails before anything is written."""
    out = []
    with open(path, newline="", encoding="utf-8") as fh:
        for n, row in enumerate(csv.DictReader(fh), start=2):
            timing = row["timing"].strip()
            lag = row["lag_months"].strip()
            var = Variable(
                variable=row["variable"].strip(),
                description=row["description"].strip(),
                native_frequency=row["native_frequency"].strip(),
                timing=timing,
                lag_months=int(lag) if lag else None,
                source_note=row["source_note"].strip(),
            )
            if timing not in TIMINGS:
                raise ValueError(f"{path.name}:{n}: unknown timing {timing!r}")
            if (timing in USABLE) != (var.lag_months is not None):
                raise ValueError(f"{path.name}:{n}: {var.variable} has timing {timing} "
                                 f"and lag {lag or 'none'}; a lag exactly when usable")
            if not var.source_note:
                raise ValueError(f"{path.name}:{n}: {var.variable} cites no source")
            out.append(var)
    names = [v.variable for v in out]
    dupes = sorted({x for x in names if names.count(x) > 1})
    if dupes:
        raise ValueError(f"{path.name}: duplicate variables {dupes}")
    return out


_MODIFIED = re.compile(r"<dcterms:modified[^>]*>([^<]+)</dcterms:modified>")


def workbook_modified(path: Path) -> dt.datetime | None:
    """The workbook's own last-modified stamp (docProps/core.xml), the
    closest thing the file has to a vintage date."""
    try:
        with zipfile.ZipFile(path) as zf:
            core = zf.read("docProps/core.xml").decode("utf-8", "replace")
    except (KeyError, zipfile.BadZipFile):
        return None
    m = _MODIFIED.search(core)
    if not m:
        return None
    return dt.datetime.fromisoformat(m.group(1).strip().replace("Z", "+00:00"))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def gkx_covariates(characteristics, states, *, char_cols: Sequence[str],
                   macro_cols: Sequence[str], date_col: str = "month"):
    """The covariates of Gu, Kelly and Xiu (2020), eq. 21:
    z_i,t = (1, x_t) (x) c_i,t, every characteristic and every
    characteristic times every macro variable.

    *characteristics* is a DataFrame with one row per (date, stock) and
    each characteristic already ranked cross-sectionally into [-1, 1] (a
    factor-panel percentile p in [0, 1] is 2p - 1). *states* is a
    DataFrame with ONE row per date and the macro variables as they are,
    raw or z-scored over time (``macro.gkx_state``), never ranked across
    stocks. They arrive separately on purpose, and the function refuses a
    macro column already sitting in the stock panel, where a ranker could
    have reached it, and a state with two rows for one date.

    Returns *characteristics* with one ``{c}_x_{m}`` column per pair; a
    date with no state gets NULL interactions, never a filled value.
    """
    leaked = sorted(set(macro_cols) & set(characteristics.columns))
    if leaked:
        raise ValueError(f"macro columns {leaked} are in the stock panel; pass them only in "
                         "the state frame, one row per date, so nothing ranks them across stocks")
    if states[date_col].duplicated().any():
        raise ValueError("the macro state must have exactly one row per date")
    for c in char_cols:
        col = characteristics[c]
        if ((col < -1) | (col > 1)).any():
            raise ValueError(f"characteristic {c} is outside [-1, 1]: rank it cross-sectionally first")
    merged = characteristics.merge(states[[date_col, *macro_cols]], on=date_col, how="left")
    out = characteristics.copy()
    for c in char_cols:
        for m in macro_cols:
            out[f"{c}_x_{m}"] = (merged[c] * merged[m]).to_numpy()
    return out


# ----------------------------------------------------------------------
# Files
# ----------------------------------------------------------------------

def fetch(dest: Path = EXTERNAL_DIR, log=print) -> dict[str, Path]:
    """Download both workbooks into *dest*, refusing anything that is not
    a workbook (Drive answers a changed link with an HTML page)."""
    dest.mkdir(parents=True, exist_ok=True)
    out = {}
    for source, (file_id, name) in WORKBOOKS.items():
        url = DOWNLOAD_URL.format(id=file_id)
        req = urllib.request.Request(url, headers={"User-Agent": "dera-pipeline"})
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
        if not body.startswith(b"PK"):
            raise RuntimeError(f"{source}: {url} did not return a workbook "
                               f"({len(body)} bytes starting {body[:40]!r})")
        path = dest / name
        path.write_bytes(body)
        log(f"  {source}: {len(body):,} bytes -> {path.relative_to(config.PROJECT_ROOT)}")
        out[source] = path
    return out


def local_files(dest: Path = EXTERNAL_DIR) -> dict[str, Path]:
    """The workbooks a previous fetch left in *dest*."""
    out = {}
    for source, (_, name) in WORKBOOKS.items():
        path = dest / name
        if not path.exists():
            raise FileNotFoundError(f"{path} is missing; run `dera load-macro` without --offline")
        out[source] = path
    return out


def read_workbook(path: Path) -> dict[str, list[tuple]]:
    """Every sheet's rows as tuples of cell values."""
    import warnings

    import openpyxl

    # The combined workbook's print header is one openpyxl cannot parse;
    # it warns and ignores it, and it carries no data. A read-only
    # workbook parses each sheet as it is iterated, so the filter has to
    # cover the reading, not just the open.
    with warnings.catch_warnings():
        warnings.filterwarnings("ignore", message="Cannot parse header or footer")
        wb = openpyxl.load_workbook(path, read_only=True, data_only=True)
        try:
            return {ws.title: list(ws.iter_rows(values_only=True)) for ws in wb.worksheets}
        finally:
            wb.close()


# ----------------------------------------------------------------------
# Database writes
# ----------------------------------------------------------------------

def write_catalogue(conn: psycopg.Connection, variables: Sequence[Variable]) -> None:
    with conn.cursor() as cur:
        cur.executemany("""
            INSERT INTO macro.gw_variable
                (variable, description, native_frequency, timing, lag_months, source_note)
            VALUES (%s, %s, %s, %s, %s, %s)
            ON CONFLICT (variable) DO UPDATE SET
                description = EXCLUDED.description,
                native_frequency = EXCLUDED.native_frequency,
                timing = EXCLUDED.timing,
                lag_months = EXCLUDED.lag_months,
                source_note = EXCLUDED.source_note
        """, [(v.variable, v.description, v.native_frequency, v.timing, v.lag_months,
               v.source_note) for v in variables])


def write_observations(
    conn: psycopg.Connection, cells: Mapping[Key, tuple[float, str]],
) -> dict[str, dict[str, int]]:
    """Replace the stored vintage with *cells*: add what is new, update
    what moved, delete what the file no longer has. Returns, per source
    workbook, how many rows were in the file, added, changed and removed."""
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TEMP TABLE tmp_gw_observation
            (LIKE macro.gw_observation) ON COMMIT DROP
        """)
        with cur.copy("COPY tmp_gw_observation (variable, frequency, period_end, value, source) "
                      "FROM STDIN") as cp:
            for (variable, frequency, end), (value, source) in cells.items():
                cp.write_row((variable, frequency, end, value, source))
        cur.execute("""
            SELECT COALESCE(t.source, o.source) AS source,
                   COUNT(t.variable)                                        AS in_file,
                   COUNT(*) FILTER (WHERE o.variable IS NULL)               AS added,
                   COUNT(*) FILTER (WHERE t.variable IS NOT NULL AND o.variable IS NOT NULL
                                      AND (t.value <> o.value OR t.source <> o.source)) AS changed,
                   COUNT(*) FILTER (WHERE t.variable IS NULL)               AS removed
            FROM tmp_gw_observation t
            FULL JOIN macro.gw_observation o
              ON o.variable = t.variable AND o.frequency = t.frequency
             AND o.period_end = t.period_end
            GROUP BY 1
        """)
        counts = {r[0]: {"in_file": r[1], "added": r[2], "changed": r[3], "removed": r[4]}
                  for r in cur.fetchall()}
        cur.execute("""
            DELETE FROM macro.gw_observation o
            WHERE NOT EXISTS (SELECT 1 FROM tmp_gw_observation t
                              WHERE t.variable = o.variable AND t.frequency = o.frequency
                                AND t.period_end = o.period_end)
        """)
        cur.execute("""
            INSERT INTO macro.gw_observation (variable, frequency, period_end, value, source)
            SELECT variable, frequency, period_end, value, source FROM tmp_gw_observation
            ON CONFLICT (variable, frequency, period_end) DO UPDATE SET
                value = EXCLUDED.value, source = EXCLUDED.source
            WHERE macro.gw_observation.value <> EXCLUDED.value
               OR macro.gw_observation.source <> EXCLUDED.source
        """)
    return counts


def drop_uncatalogued(conn: psycopg.Connection, variables: Sequence[Variable]) -> int:
    """Remove catalogue rows the CSV no longer has (their observations went
    with the vintage that carried them)."""
    with conn.cursor() as cur:
        cur.execute("DELETE FROM macro.gw_variable WHERE NOT (variable = ANY(%s))",
                    ([v.variable for v in variables],))
        return cur.rowcount


def record_load(conn: psycopg.Connection, source: str, path: Path,
                counts: Mapping[str, int], first: dt.date | None, last: dt.date | None) -> None:
    file_id, _ = WORKBOOKS[source]
    with conn.cursor() as cur:
        cur.execute("""
            INSERT INTO macro.gw_load
                (source, url, sha256, workbook_modified, rows_in_file, rows_added,
                 rows_changed, rows_removed, first_period, last_period)
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
        """, (source, DOWNLOAD_URL.format(id=file_id), sha256(path), workbook_modified(path),
              counts.get("in_file", 0), counts.get("added", 0), counts.get("changed", 0),
              counts.get("removed", 0), first, last))


def load(conn: psycopg.Connection, *, offline: bool = False, log=print) -> dict:
    """Fetch (or reuse) both workbooks, check they agree, and replace the
    stored vintage. Returns the summary."""
    files = local_files() if offline else fetch(log=log)
    combined = parse_workbook(read_workbook(files["gwz_combined"]))
    gw2008 = parse_workbook(read_workbook(files["gw2008"]), GW2008_RENAMES)
    bad = disagreements(combined, gw2008)
    if bad:
        sample = "; ".join(f"{k[0]} {k[1]} {k[2]}: {x} vs {y}" for k, x, y in bad[:5])
        raise RuntimeError(f"the two workbooks disagree on {len(bad)} shared cells, "
                           f"nothing loaded: {sample}")
    shared = len(combined.keys() & gw2008.keys())
    cells = merge(combined, gw2008)

    variables = read_catalogue()
    missing = sorted({k[0] for k in cells} - {v.variable for v in variables})
    if missing:
        raise RuntimeError(f"variables with no row in {CATALOGUE.name} (add one, with a "
                           f"timing class and a cited source, before loading): {missing}")

    write_catalogue(conn, variables)
    counts = write_observations(conn, cells)
    dropped = drop_uncatalogued(conn, variables)
    for source, path in files.items():
        ends = [k[2] for k, (_, s) in cells.items() if s == source]
        record_load(conn, source, path, counts.get(source, {}),
                    min(ends, default=None), max(ends, default=None))
    return {
        "cells": len(cells), "shared_cells_agreeing": shared, "counts": counts,
        "variables": len(variables), "catalogue_rows_dropped": dropped,
        "usable": sorted(v.variable for v in variables if v.timing in USABLE),
        "vintage": {s: workbook_modified(p) for s, p in files.items()},
        "last_period": max((k[2] for k in cells), default=None),
    }


def ddl_path() -> Path:
    return config.SQL_DIR / "08_macro" / "010_goyal_welch.sql"


def print_summary(summary: dict, out=sys.stdout) -> None:
    out.write(f"{summary['cells']:,} cells stored; the {summary['shared_cells_agreeing']:,} "
              f"cells both workbooks carry agree\n")
    for source, c in sorted(summary["counts"].items()):
        vintage = summary["vintage"].get(source)
        out.write(f"  {source}: {c['in_file']:,} in file, {c['added']:,} added, "
                  f"{c['changed']:,} changed, {c['removed']:,} removed"
                  f"{f' (workbook modified {vintage:%Y-%m-%d})' if vintage else ''}\n")
    out.write(f"last period {summary['last_period']}; {summary['variables']} variables catalogued, "
              f"{len(summary['usable'])} usable point in time: {', '.join(summary['usable'])}\n")
    if any(c["changed"] or c["removed"] for c in summary["counts"].values()):
        out.write("note: this vintage restated values already stored (changed/removed above)\n")
