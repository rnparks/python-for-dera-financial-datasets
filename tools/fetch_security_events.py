"""Derive security lifecycle events from EDGAR submissions (slice tool).

SUPERSEDED FOR PIPELINE USE. The pipeline ingests the same events for all
17,015 spine CIKs from the bulk archive via `dera_pipeline.filings`:

    uv run dera fetch-filing-index      # ~1.5 GB, one request
    uv run dera build-security-model

This script walks the per-CIK submissions API for the hand-picked SLICE
below and is retained for iterating on the classification rules at a
scale where the answers are known in advance. Nothing in the pipeline
imports it.

WHY THIS EXISTS. The pipeline is point-in-time correct on facts and not on
securities. `sec_gold.fact_asof` knows what any number looked like on any
date, but nothing knows when a security began trading or stopped. Without
that, a historical universe cannot exclude a company before its IPO
(future-existence bias) or retain it through its delisting (survivorship
bias).

WHY NOT THE DERA DATASETS. `sec_silver.sub_silver` carries only filings that
contain XBRL financial statements -- 10-K, 10-Q, 20-F, S-1, 8-K. It holds
ZERO Form 25, Form 15 or 8-A, which are precisely the listing and delisting
notifications. Verified against the live database. The lifecycle is simply
not in the data this project ingests today.

WHY NOT THE CURRENT-STATE FILES. company_tickers.json and the submissions
API `tickers` field are current-state and therefore survivorship-biased in
exactly the way this work exists to remove. SVB Financial is the proof:

    "tickers": []   "exchanges": []

SEC has erased the ticker of a company that was an S&P 500 member until
2023. Its filing history, however, is intact and dated:

    8-A12B    2019-12-06   registration of a class on an exchange
    25-NSE    2023-05-02   notification of removal from listing
    15-12G    2025-01-24   deregistration

So the spine is built from FILING EVENTS, which are immutable and dated,
never from any file describing the present.

PAGINATION. `filings.recent` caps at 1000 filings. A company that files
often pushes its own 8-A off the end -- Apple's `recent` reaches back only
to 2015 while its 8-A is far older. The overflow files listed under
`filings.files` must be followed or long-lived issuers silently lose their
listing date.

Writes two files: data/reference/security_events.csv (one row per
(cik, event)) and data/reference/company_names.csv. Turning discrete
events into validity intervals happens in SQL, not here, so the raw
evidence stays auditable -- the same split `fetch_ticker_history.py` uses.

Run:  uv run python tools/fetch_security_events.py
"""

from __future__ import annotations

import csv
import json
import sys
import time
import urllib.error
import urllib.request

from dera_pipeline import config

SUBMISSIONS_URL = "https://data.sec.gov/submissions/CIK{cik:010d}.json"
OVERFLOW_URL = "https://data.sec.gov/submissions/{name}"

REQUEST_PAUSE_SECS = 0.15  # SEC allows 10 req/sec; stay well under
TIMEOUT_SECS = 60

# The Phase 0 slice. Each CIK earns its place by exercising a specific
# requirement; none is here to pad a sample.
SLICE: dict[int, str] = {
    719739:  "bankruptcy; 25-NSE 2023-05-02; live API has erased its ticker",
    1310067: "bankruptcy after long decline (Sears Holdings)",
    886158:  "bankruptcy (Bed Bath & Beyond, original registrant)",
    1130713: "name reuse: a DIFFERENT CIK now carries the Bed Bath name",
    1418091: "acquisition, taken private (Twitter)",
    1652044: "multi-class issuer (Alphabet)",
    1288776: "predecessor registrant of the above (Google Inc)",
    1451512: "genuine ticker change TRTC -> UNRV on one CIK",
    1326801: "ticker change FB -> META on one CIK, well-known date",
    1321655: "2020 direct listing (Palantir)",
    1679788: "2021 direct listing (Coinbase)",
    1874178: "2021 IPO (Rivian)",
    1318605: "index addition effective 2020-12-21 (Tesla)",
    1067983: "multi-class with an excluded duplicate expression (Berkshire)",
    320193:  "survivor control, 8-A predates the recent-filings window (Apple)",
    789019:  "survivor control (Microsoft)",
    1045810: "survivor control, non-December fiscal year (NVIDIA)",
    19617:   "survivor control, bank (JPMorgan)",
}

# Form-prefix to event mapping.
#
# 8-A registers a class of securities on an exchange and is the closest
# thing EDGAR has to a listing notification. Form 25 is the removal
# notification -- 25-NSE is the exchange-filed variant, which is what
# appears when an exchange delists an issuer rather than the issuer
# withdrawing voluntarily. Form 15 is deregistration and comes LATER than
# delisting; it means the reporting obligation ended, not that trading
# stopped, so the two must not be conflated.
EVENT_RULES: tuple[tuple[str, str], ...] = (
    ("8-A",   "LISTING_REGISTRATION"),
    ("25",    "DELISTING_NOTICE"),
    ("15-",   "DEREGISTRATION"),
    ("S-1",   "IPO_REGISTRATION"),
    ("F-1",   "IPO_REGISTRATION"),
    ("424B4", "IPO_PRICING"),
    ("424B1", "IPO_PRICING"),
    # Periodic reports are not lifecycle events themselves, but they are
    # the evidence that decides whether a Form 25 ended the company or
    # merely retired one class of its securities. JPMorgan has filed 46
    # Form 25s and has never been delisted; Palantir filed one the same
    # day it filed a new 8-A12B, moving NYSE -> Nasdaq. Without the
    # continued-reporting signal, either would read as a delisting.
    ("10-K",  "PERIODIC_REPORT"),
    ("10-Q",  "PERIODIC_REPORT"),
    ("20-F",  "PERIODIC_REPORT"),
    ("40-F",  "PERIODIC_REPORT"),
)


def classify(form: str) -> str | None:
    """Map a form type to a lifecycle event, or None if it isn't one.

    Amendments (`25-NSE/A`, `8-A12B/A`) are treated as their base form:
    an amended delisting notice still evidences a delisting. Order
    matters -- '25' must not swallow '25-NSE' differently, and both are
    DELISTING_NOTICE anyway.
    """
    f = form.upper()
    for prefix, event in EVENT_RULES:
        if f.startswith(prefix):
            return event
    return None


def _get_json(url: str):
    req = urllib.request.Request(url, headers={"User-Agent": config.sec_user_agent()})
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as resp:
        return json.loads(resp.read().decode("utf-8", errors="replace"))


def fetch_filings(cik: int) -> tuple[dict, list[tuple[str, str, str]]]:
    """Return (metadata, [(form, filing_date, accession)]) for one CIK.

    Follows `filings.files` overflow pages. Without this, any issuer with
    more than 1000 filings loses its oldest history -- which is exactly
    where the 8-A listing registration lives.
    """
    doc = _get_json(SUBMISSIONS_URL.format(cik=cik))
    rows: list[tuple[str, str, str]] = []

    def absorb(block: dict) -> None:
        forms = block.get("form", [])
        dates = block.get("filingDate", [])
        accns = block.get("accessionNumber", [])
        for f, d, a in zip(forms, dates, accns):
            rows.append((f, d, a))

    absorb(doc["filings"]["recent"])
    for extra in doc["filings"].get("files", []):
        time.sleep(REQUEST_PAUSE_SECS)
        absorb(_get_json(OVERFLOW_URL.format(name=extra["name"])))

    return doc, rows


def main(argv: list[str] | None = None) -> int:
    out_events = config.REFERENCE_DIR / "security_events.csv"
    out_names = config.REFERENCE_DIR / "company_names.csv"
    out_events.parent.mkdir(parents=True, exist_ok=True)

    ev_rows: list[dict] = []
    nm_rows: list[dict] = []

    for cik, why in SLICE.items():
        try:
            doc, filings = fetch_filings(cik)
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, KeyError) as exc:
            print(f"  CIK {cik}: fetch failed ({exc})", file=sys.stderr)
            continue

        name = doc.get("name", "")
        n_ev = 0
        for form, fdate, adsh in filings:
            event = classify(form)
            if event is None:
                continue
            ev_rows.append({
                "cik": cik, "event_type": event, "event_date": fdate,
                "form": form, "adsh": adsh,
            })
            n_ev += 1

        # First filing of any kind: the floor on company existence in
        # EDGAR. Not a trading date, and deliberately labelled as such.
        # Skip falsy dates before taking the minimum, matching
        # dera_pipeline.filings.iter_events. Without this an EDGAR record
        # with an empty filingDate yields event_date="" and the two
        # implementations disagree on the same input.
        filing_dates = [d for _, d, _ in filings if d]
        if filing_dates:
            ev_rows.append({
                "cik": cik, "event_type": "FIRST_EDGAR_FILING",
                "event_date": min(filing_dates),
                "form": "", "adsh": "",
            })

        # Historical names, so a renamed company stays one identity.
        for fn in doc.get("formerNames", []):
            nm_rows.append({
                "cik": cik, "name": fn.get("name", ""),
                "valid_from": (fn.get("from") or "")[:10],
                "valid_to": (fn.get("to") or "")[:10],
            })
        nm_rows.append({"cik": cik, "name": name, "valid_from": "", "valid_to": ""})

        live_tickers = ",".join(doc.get("tickers", []) or [])
        print(f"  {cik:>8}  {name[:34]:<34} events={n_ev:<3} "
              f"live_tickers={live_tickers or '(none)':<12} {why[:40]}")
        time.sleep(REQUEST_PAUSE_SECS)

    with out_events.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["cik", "event_type", "event_date", "form", "adsh"])
        w.writeheader()
        w.writerows(ev_rows)
    with out_names.open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=["cik", "name", "valid_from", "valid_to"])
        w.writeheader()
        w.writerows(nm_rows)

    print(f"\nWrote {len(ev_rows)} events to {out_events}")
    print(f"Wrote {len(nm_rows)} name rows to {out_names}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
