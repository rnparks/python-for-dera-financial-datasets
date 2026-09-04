"""EDGAR filing-index ingestion: the security lifecycle at full scale.

WHY A SECOND INGESTION PATH. The DERA Financial Statement Data Sets carry
only filings that contain XBRL financial statements -- 10-K, 10-Q, 20-F,
S-1, 8-K. Verified against the live database: `sec_silver.sub_silver`
holds ZERO Form 25, Form 15 or 8-A. Those are the delisting and listing
notifications, so the entire security lifecycle is absent from the data
this project ingests, and no amount of work on the DERA tables recovers
it.

WHY THE BULK ARCHIVE RATHER THAN THE PER-CIK API. Both work; the archive
is one request instead of roughly 25,000, which is politer to SEC and
reproducible from a single artifact. It is ~1.5 GB and gitignored.

WHY ONLY SOME CIKS. The archive covers every filer EDGAR has ever seen,
around a million. We want the ~17,000 that appear in
`sec_reference.company` -- the ones with fundamentals to join to. The rest
is noise for this purpose, and the zip's central directory makes reading
named members cheap, so we look up exactly what we need rather than
walking the archive.

PAGINATION. `filings.recent` caps at 1000 entries. A company that files
often pushes its own 8-A off the end -- Apple's `recent` reaches back only
to 2015 while its 8-A is older -- so the overflow members listed under
`filings.files` must be read too, or long-lived issuers silently lose
their listing evidence.
"""

from __future__ import annotations

import json
import re
import zipfile
from collections.abc import Iterable, Iterator
from pathlib import Path

import psycopg

from . import config

BULK_URL = "https://www.sec.gov/Archives/edgar/daily-index/bulkdata/submissions.zip"
BULK_PATH = config.PROJECT_ROOT / "data" / "edgar" / "submissions.zip"

# Form type to lifecycle event. The single definition: tools/
# fetch_security_events.py imports it rather than carrying a copy.
#
# ANCHORED PATTERNS, NOT PREFIXES. The first version matched on
# `form.startswith(prefix)`, and "25" therefore swallowed 253G1-253G4 --
# Regulation A offering circulars, which are a capital raise, the
# opposite of a delisting. 771 of them were classified as delisting
# notices and 54 securities were given a delisting_date on the day they
# raised money. "S-1" likewise took S-11 (REIT registrations) and "F-1"
# took F-10 (Canadian shelf registrations). Each pattern below names the
# exact forms it accepts; an amendment (/A) or MEF variant is listed
# where it evidences the same event as its base form.
#
# Periodic reports are not lifecycle events themselves. They are the
# evidence that decides whether a Form 25 ended the company or merely
# retired one class of its securities, and whether an 8-A is a first
# listing or a later note registration. Both discriminators are
# behavioural and both need this stream. The 10-K and 10-Q patterns are
# deliberately open-ended: 10-K405, 10-KSB, 10-KT and their amendments
# are all periodic reports.
EVENT_RULES: tuple[tuple[str, str], ...] = (
    (r"8-A12[BG](/A)?",          "LISTING_REGISTRATION"),
    (r"25(-NSE)?(/A)?",          "DELISTING_NOTICE"),
    (r"15F?-(12B|12G|15D)(/A)?", "DEREGISTRATION"),
    (r"S-1(/A|MEF)?",            "IPO_REGISTRATION"),
    (r"F-1(/A|MEF)?",            "IPO_REGISTRATION"),
    (r"424B[14]",                "IPO_PRICING"),
    (r"10-K.*",                  "PERIODIC_REPORT"),
    (r"10-Q.*",                  "PERIODIC_REPORT"),
    (r"20-F(/A)?",               "PERIODIC_REPORT"),
    (r"40-F(/A)?",               "PERIODIC_REPORT"),
)

_COMPILED_RULES: tuple[tuple[re.Pattern[str], str], ...] = tuple(
    (re.compile(rf"^(?:{pattern})$"), event) for pattern, event in EVENT_RULES
)


def classify(form: str) -> str | None:
    """Map a form type to a lifecycle event, or None if it is not one.

    Whole-string match against EVENT_RULES, case-insensitive on the
    form. Amendments are treated as their base form where listed: an
    amended delisting notice still evidences a delisting.
    """
    f = form.strip().upper()
    for pattern, event in _COMPILED_RULES:
        if pattern.match(f):
            return event
    return None


def target_ciks(conn: psycopg.Connection) -> list[int]:
    """The CIKs worth extracting: every company in the spine."""
    with conn.cursor() as cur:
        cur.execute("SELECT cik FROM sec_reference.company ORDER BY cik")
        return [r[0] for r in cur.fetchall()]


def _read_member(zf: zipfile.ZipFile, name: str) -> dict | None:
    try:
        with zf.open(name) as fh:
            return json.loads(fh.read().decode("utf-8", errors="replace"))
    except (KeyError, json.JSONDecodeError):
        return None


def iter_events(zf: zipfile.ZipFile, ciks: Iterable[int],
                names_sink: list | None = None) -> Iterator[tuple]:
    """Yield (cik, event_type, event_date, form, adsh) lifecycle rows.

    Name rows are appended to *names_sink* during the same pass rather
    than collected by a second walk of the archive. Decompressing ~17,000
    members is the expensive part of this ingest and there is no reason
    to pay for it twice; the names are a few tens of thousands of short
    tuples, so buffering them costs nothing.

    Missing CIKs are skipped silently: a company can be in the DERA spine
    and absent from the submissions archive, and that is a coverage fact
    to measure afterwards rather than an error to raise here.
    """
    for cik in ciks:
        doc = _read_member(zf, f"CIK{cik:010d}.json")
        if doc is None:
            continue

        # Historical names, collected here rather than by a second walk.
        # Bed Bath & Beyond is why they matter: CIK 886158 is now named
        # "20230930-DK-Butterfly-1, Inc." while a DIFFERENT registrant,
        # CIK 1130713, carries the Bed Bath name today. Matching on
        # current name alone merges two companies that were never one.
        if names_sink is not None:
            for fn in doc.get("formerNames", []) or []:
                names_sink.append((cik, (fn.get("name") or "")[:200],
                                   (fn.get("from") or "")[:10],
                                   (fn.get("to") or "")[:10]))
            if doc.get("name"):
                names_sink.append((cik, doc["name"][:200], "", ""))

        blocks = [doc["filings"]["recent"]]
        for extra in doc["filings"].get("files", []):
            sub = _read_member(zf, extra["name"])
            if sub is not None:
                blocks.append(sub)

        earliest: str | None = None
        for block in blocks:
            for form, fdate, adsh in zip(block.get("form", []),
                                         block.get("filingDate", []),
                                         block.get("accessionNumber", [])):
                if not fdate:
                    continue
                if earliest is None or fdate < earliest:
                    earliest = fdate
                event = classify(form)
                if event is not None:
                    yield (cik, event, fdate, form, adsh)

        if earliest is not None:
            yield (cik, "FIRST_EDGAR_FILING", earliest, "", "")


def _copy_rows(conn: psycopg.Connection, table: str, columns: tuple[str, ...],
               rows: Iterator[tuple]) -> int:
    """Stream tuples into *table* via COPY FROM STDIN. Returns row count."""
    col_list = ", ".join(columns)
    n = 0
    with conn.cursor() as cur, cur.copy(f"COPY {table} ({col_list}) FROM STDIN") as cp:
        for row in rows:
            cp.write_row(row)
            n += 1
    return n


def load_security_events(conn: psycopg.Connection,
                         zip_path: Path | None = None) -> dict[str, int]:
    """Extract lifecycle events for every spine CIK into staging."""
    path = zip_path or BULK_PATH
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found — run `dera fetch-filing-index` first")

    ciks = target_ciks(conn)
    with conn.cursor() as cur:
        cur.execute("TRUNCATE sec_reference.security_event_raw")
        cur.execute("TRUNCATE sec_reference.company_name_raw")

    names: list[tuple] = []
    with zipfile.ZipFile(path) as zf:
        n_ev = _copy_rows(
            conn, "sec_reference.security_event_raw",
            ("cik", "event_type", "event_date", "form", "adsh"),
            iter_events(zf, ciks, names_sink=names))
    n_nm = _copy_rows(
        conn, "sec_reference.company_name_raw",
        ("cik", "name", "valid_from", "valid_to"), iter(names))

    return {"ciks_requested": len(ciks), "events": n_ev, "names": n_nm}
