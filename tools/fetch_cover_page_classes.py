"""Derive share-class to ticker mappings from 10-K cover pages.

WHY. `sec_reference.share_class` is an allowlist: a dual-class issuer
gets per-class share counts, and therefore a market cap, only once each
class is mapped to the ticker whose price applies. The mapping cannot be
inferred from tickers (Alphabet files three classes against two
tickers) and the DERA numeric datasets do not carry it. The issuer's own
10-K does: since 2019 every cover page tags `dei:TradingSymbol`,
`dei:SecurityExchangeName` and `dei:Security12bTitle` in inline XBRL,
each in a context dimensioned by `us-gaap:StatementClassOfStockAxis`,
and that member name is exactly what DERA renders into
`num_silver.segments` (`ClassOfStock=CommonClassA;`). So the mapping is
readable from the filing, character for character, with the accession
number as its citation.

WHAT THIS DOES. For each CIK: find the latest 10-K in the bulk
submissions archive, download its primary document from EDGAR, parse
the inline XBRL, and record every class-dimensioned cover fact. Listed
classes (a trading symbol, an exchange) become candidate
`share_class_map.csv` rows with `source = mapped_filing` and a note
citing the accession number. Classes the cover page marks as having no
trading symbol are REPORTED, not mapped: an unlisted class is priced
through the listed class it converts into at a ratio the cover page does
not state, and a ratio must be cited, never assumed.

WHAT IT DOES NOT DO. It does not touch the database or the mapping file
unless told to (`--write-map`), and it maps nothing for a filer without
an inline-XBRL 10-K (foreign 20-F filers, pre-2019 delistings). The
class label is filtered against the members the issuer actually files
share counts under, so cover-page lines for notes and preferreds that
never appear on a share-count fact are reported but not mapped.

Run:  uv run python tools/fetch_cover_page_classes.py --sp500        # the dual-class S&P 500 issuers
      uv run python tools/fetch_cover_page_classes.py --cik 1326801 --cik 320187
      uv run python tools/fetch_cover_page_classes.py --sp500 --write-map
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile

from lxml import etree

from dera_pipeline import config, db, filings

ARCHIVE_URL = "https://www.sec.gov/Archives/edgar/data/{cik}/{adsh_nodash}/{doc}"
REQUEST_PAUSE_SECS = 0.5
TIMEOUT_SECS = 180
OUT_NAME = "cover_page_classes.csv"
MAP_NAME = "share_class_map.csv"
DATE_MAX = __import__("datetime").date(9999, 12, 31)
REPORT: list[str] = []   # human-review lines collected while mapping

NS = {
    "ix": "http://www.xbrl.org/2013/inlineXBRL",
    "xbrli": "http://www.xbrl.org/2003/instance",
    "xbrldi": "http://xbrl.org/2006/xbrldi",
}
CLASS_AXIS = "us-gaap:StatementClassOfStockAxis"
COVER_FACTS = ("dei:TradingSymbol", "dei:SecurityExchangeName",
               "dei:Security12bTitle", "dei:NoTradingSymbolFlag")

SP500_DUAL_CLASS_SQL = """
    WITH sp AS (
        SELECT cik FROM sec_reference.index_members('SP500', CURRENT_DATE))
    SELECT n.cik
    FROM sec_silver.num_silver n JOIN sp ON sp.cik = n.cik
    WHERE n.tag IN ('EntityCommonStockSharesOutstanding', 'CommonStockSharesOutstanding',
                    'CommonStockSharesIssued')
      AND n.uom = 'shares' AND n.value > 0
      AND n.segments LIKE 'ClassOfStock=%%' AND n.segments NOT LIKE '%%;%%;%%'
      AND n.value_date >= DATE '2008-01-01'
    GROUP BY n.cik HAVING COUNT(DISTINCT n.segments) >= 2
    ORDER BY n.cik
"""

SHARE_COUNT_MEMBERS_SQL = """
    SELECT DISTINCT replace(replace(n.segments, 'ClassOfStock=', ''), ';', '')
    FROM sec_silver.num_silver n
    WHERE n.cik = %s
      AND n.tag IN ('EntityCommonStockSharesOutstanding', 'CommonStockSharesOutstanding',
                    'CommonStockSharesIssued', 'WeightedAverageNumberOfSharesOutstandingBasic')
      AND n.uom = 'shares' AND n.value > 0
      AND n.segments LIKE 'ClassOfStock=%%' AND n.segments NOT LIKE '%%;%%;%%'
"""


def latest_10k(zf: zipfile.ZipFile, cik: int) -> tuple[str, str, str, str] | None:
    """(adsh, filing_date, primary_document, company_name) of the newest 10-K."""
    try:
        with zf.open(f"CIK{cik:010d}.json") as fh:
            doc = json.loads(fh.read().decode("utf-8", errors="replace"))
    except KeyError:
        return None
    recent = doc["filings"]["recent"]
    best = None
    for form, fdate, adsh, prim in zip(recent.get("form", []), recent.get("filingDate", []),
                                       recent.get("accessionNumber", []),
                                       recent.get("primaryDocument", [])):
        if form == "10-K" and prim and (best is None or fdate > best[1]):
            best = (adsh, fdate, prim, doc.get("name", ""))
    return best


def fetch_document(cik: int, adsh: str, doc: str) -> bytes:
    url = ARCHIVE_URL.format(cik=cik, adsh_nodash=adsh.replace("-", ""), doc=doc)
    req = urllib.request.Request(url, headers={"User-Agent": config.sec_user_agent()})
    with urllib.request.urlopen(req, timeout=TIMEOUT_SECS) as resp:
        return resp.read()


def _member_label(qname: str) -> str:
    """`us-gaap:CommonClassAMember` -> `CommonClassA`, as DERA renders it."""
    local = qname.split(":", 1)[-1].strip()
    return local[:-6] if local.endswith("Member") else local


def parse_cover(raw: bytes) -> list[dict]:
    """Every class-dimensioned cover fact, one dict per (class, fact)."""
    parser = etree.XMLParser(recover=True, huge_tree=True)
    root = etree.fromstring(raw, parser=parser)
    if root is None:
        return []

    # context id -> class member label (only contexts on the class axis)
    ctx_class: dict[str, str] = {}
    for ctx in root.iter(f"{{{NS['xbrli']}}}context"):
        cid = ctx.get("id")
        for mem in ctx.iter(f"{{{NS['xbrldi']}}}explicitMember"):
            if mem.get("dimension") == CLASS_AXIS and mem.text:
                ctx_class[cid] = _member_label(mem.text)

    # Facts grouped by context. A context on the class axis yields the
    # member label directly. A context WITHOUT the axis is how an issuer
    # with a single registered class files its cover -- Meta tags META
    # and "Class A Common Stock" in the default context while reporting
    # both classes' share counts dimensioned -- so those are kept with an
    # empty label and resolved against the issuer's share-count members
    # from the title, in main().
    facts: dict[str, dict[str, str]] = {}
    for el in root.iter(f"{{{NS['ix']}}}nonNumeric"):
        name = el.get("name")
        if name not in COVER_FACTS:
            continue
        ctx = el.get("contextRef", "")
        key = ctx_class.get(ctx) or f"__ctx__{ctx}"
        value = " ".join("".join(el.itertext()).split())
        facts.setdefault(key, {})[name] = value

    rows = []
    for key, vals in facts.items():
        symbol = vals.get("dei:TradingSymbol", "")
        no_symbol = vals.get("dei:NoTradingSymbolFlag", "").lower() == "true"
        rows.append({
            "class_member": "" if key.startswith("__ctx__") else key,
            # Some covers wrap the symbol in typographic quotes (CBRE);
            # keep only symbol characters.
            "trading_symbol": "" if no_symbol else re.sub(r"[^A-Z0-9 .\-]", "", symbol.upper()).strip().replace(".", "-"),
            "exchange": vals.get("dei:SecurityExchangeName", ""),
            "security_title": vals.get("dei:Security12bTitle", ""),
        })
    return rows


def match_title_to_member(title: str, members: set[str]) -> str | None:
    """Resolve an undimensioned cover line to one share-count member.

    Only the issuer's own words are used: "Class B Common Stock" names
    class B, and the member that carries class B's share counts is the
    one whose label contains ClassB. Exactly one match maps; zero or
    several map nothing and are reported. A title with no class at all
    maps only when the issuer has exactly one share-count member.
    """
    m = re.search(r"\bclass\s+([A-Z0-9]+)\b", title or "", re.I)
    if m:
        key = f"class{m.group(1)}".lower()
        hits = [mem for mem in members if key in mem.lower()]
        exact = [mem for mem in hits if mem.lower().endswith(key)]
        hits = exact or hits
        return hits[0] if len(hits) == 1 else None
    # No class in the title. "Common Stock" names the member CommonStock
    # exactly (Hubbell, Regeneron and Mosaic collapsed a dual-class
    # structure and now file under it); otherwise only a lone member.
    if re.match(r"^\s*common\s+stock\b", title or "", re.I) and "CommonStock" in members:
        return "CommonStock"
    return next(iter(members)) if len(members) == 1 else None


def candidate_map_rows(conn, cik: int, name: str, adsh: str, fdate: str,
                       cover_rows: list[dict], members: set[str]) -> list[dict]:
    """Listed classes that carry share counts -> share_class_map rows.

    Symbols are written in the crosswalk's spelling (the cover says BFA,
    SEC's ticker file says BF-A) so the mapping joins to listing and
    universe rows. A mapped class covers the symbol's whole life, not
    merely the crosswalk's first sighting of it. Where the CIK has an
    ENDED symbol that no class claims and that overlapped nothing but
    claimed symbols -- a plain ticker change such as FB then META -- and
    the issuer has exactly one listed class, that symbol is the same
    class under its former name: it gets its own dated row and the
    current symbol starts where it ended. A retired symbol that also
    overlapped an unclaimed line (Block's SQ beside its BSQKZ notes) is
    reported instead, because the evidence is ambiguous.
    """
    with conn.cursor() as cur:
        cur.execute("SELECT ticker, MIN(valid_from), "
                    "CASE WHEN bool_or(valid_to IS NULL) THEN NULL ELSE MAX(valid_to) END "
                    "FROM sec_reference.company_ticker WHERE cik = %s "
                    "GROUP BY ticker ORDER BY MIN(valid_from)", (cik,))
        spans = {t: (vf, vt) for t, vf, vt in cur.fetchall()}

    def spelled(sym: str) -> str:
        if sym in spans:
            return sym
        for cand in (sym[:-1] + "-" + sym[-1], sym.replace(" ", "-"), sym.replace(" ", "")):
            if cand in spans:
                return cand
        return sym

    listed = [dict(r, trading_symbol=spelled(r["trading_symbol"]))
              for r in cover_rows if r["trading_symbol"] and r["class_member"] in members]
    def note_for(r: dict, sym: str) -> str:
        how = ("dimensioned by class on the cover" if r.get("resolved") == "dimensioned"
               else f"cover title '{r['security_title']}' matched to member {r['class_member']}")
        return (f"{name} 10-K {adsh} ({fdate}) cover page: "
                f"{r['security_title'] or r['class_member']} listed as {sym} on "
                f"{r['exchange'] or 'unspecified exchange'}; {how}")

    def row(cls: str, sym: str, eff_from: str, eff_to: str, note: str) -> dict:
        return {"cik": cik, "class_label": cls, "ticker": sym, "prices_with_ticker": "",
                "conversion_ratio": "", "is_excluded": "false", "effective_from": eff_from,
                "effective_to": eff_to, "source": "mapped_filing", "source_note": note}

    def same_line(a: str, b: str) -> bool:
        return a.replace("-", "").replace(".", "") == b.replace("-", "").replace(".", "")

    def chain(cls: str, syms: list[str], r: dict) -> list[dict]:
        """Rows for one class across the symbols it has carried, in time order."""
        # A cover symbol the crosswalk never saw (Carnival's CUK line) has
        # no span: it sorts last and its row is open-ended from 1900.
        seq = sorted(syms, key=lambda t: spans.get(t, (DATE_MAX, None))[0])
        rows, prev_end = [], None
        for i, sym in enumerate(seq):
            vf, vt = spans.get(sym, (None, None))
            eff_from = prev_end.isoformat() if prev_end else "1900-01-01"
            eff_to = vt.isoformat() if (vt is not None and i < len(seq) - 1) else ""
            how = (note_for(r, sym) if sym == r["trading_symbol"] else
                   f"{name}: {sym} is the earlier symbol of the same class per crosswalk "
                   f"continuity ({vf} to {vt}); class identity from 10-K {adsh}")
            rows.append(row(cls, sym, eff_from, eff_to, how))
            prev_end = vt
        return rows

    out = []
    used: set[str] = set()
    for r in listed:
        sym = r["trading_symbol"]
        # The symbol's own spelling variants over time (BFA then BF-A).
        variants = [t for t in spans if same_line(t, sym)] or [sym]
        used.update(variants)
        out.extend(chain(r["class_member"], variants, r))

    if len(listed) == 1:
        # A predecessor symbol: retired, started earlier, and ended within
        # one capture window of the current symbol's first sighting -- the
        # file carried FB and META together for a few weeks, and SQ ended
        # on the day XYZ began. A retired line that ran ALONGSIDE the
        # current symbol for longer (Hubbell's stale HUBA beside HUBB, the
        # KKR preferreds) is reported, never chained.
        r = listed[0]
        cur_first = min((spans[t][0] for t in used if t in spans), default=None)
        cls = r["class_member"]
        for sym, (vf, vt) in spans.items():
            if sym in used or vt is None:
                continue
            if cur_first is not None and vf < cur_first and abs((vt - cur_first).days) <= 200:
                # rebuild the chain with the predecessor included
                out = [o for o in out if o["class_label"] != cls]
                used.add(sym)
                out.extend(chain(cls, [t for t in used if t in spans], r))
            else:
                REPORT.append(f"{cik} {name}: retired symbol {sym} ({vf} to {vt}) not chained to "
                              f"{r['trading_symbol']}: it did not end when the current symbol "
                              f"began; map by hand if it was the same class")
    if not any(o["ticker"] == r["trading_symbol"] for r in listed for o in out):
        for r in listed:
            out.append(row(r["class_member"], r["trading_symbol"], "1900-01-01", "",
                           note_for(r, r["trading_symbol"])))
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--cik", type=int, action="append", default=[], help="CIK to process (repeatable)")
    parser.add_argument("--sp500", action="store_true",
                        help="process every dual-class S&P 500 issuer (two or more ClassOfStock members)")
    parser.add_argument("--write-map", action="store_true",
                        help=f"append candidate rows for listed classes to data/reference/{MAP_NAME}")
    args = parser.parse_args(argv)

    if not filings.BULK_PATH.exists():
        print(f"error: {filings.BULK_PATH} not found; run `dera fetch-filing-index`", file=sys.stderr)
        return 1

    with db.get_conn() as conn:
        ciks = list(args.cik)
        if args.sp500:
            with conn.cursor() as cur:
                cur.execute(SP500_DUAL_CLASS_SQL)
                ciks += [r[0] for r in cur.fetchall()]
        ciks = sorted(set(ciks))
        if not ciks:
            print("nothing to do: pass --cik or --sp500", file=sys.stderr)
            return 2
        with conn.cursor() as cur:
            cur.execute("SELECT cik FROM sec_reference.share_class GROUP BY cik")
            already = {r[0] for r in cur.fetchall()}

        out_path = config.REFERENCE_DIR / OUT_NAME
        map_path = config.REFERENCE_DIR / MAP_NAME
        cover_rows_all: list[dict] = []
        map_rows_all: list[dict] = []
        unlisted_report: list[str] = []

        with zipfile.ZipFile(filings.BULK_PATH) as zf:
            for cik in ciks:
                tenk = latest_10k(zf, cik)
                if tenk is None:
                    print(f"  {cik:>8}: no 10-K with a primary document in the archive")
                    continue
                adsh, fdate, prim, name = tenk
                try:
                    raw = fetch_document(cik, adsh, prim)
                except (urllib.error.URLError, TimeoutError) as exc:
                    print(f"  {cik:>8}: download failed ({exc})", file=sys.stderr)
                    continue
                time.sleep(REQUEST_PAUSE_SECS)
                rows = parse_cover(raw)
                with conn.cursor() as cur:
                    cur.execute(SHARE_COUNT_MEMBERS_SQL, (cik,))
                    members = {r[0] for r in cur.fetchall()}
                for r in rows:
                    if r["class_member"]:
                        r["resolved"] = "dimensioned"
                    else:
                        hit = match_title_to_member(r["security_title"], members)
                        r["class_member"] = hit or ""
                        r["resolved"] = "title" if hit else "unresolved"
                for r in rows:
                    r_out = {"cik": cik, "name": name, "adsh": adsh, "filing_date": fdate,
                             "class_member": r["class_member"], "trading_symbol": r["trading_symbol"],
                             "exchange": r["exchange"], "security_title": r["security_title"],
                             "resolved": r["resolved"],
                             "on_share_count_facts": bool(r["class_member"]) and r["class_member"] in members}
                    cover_rows_all.append(r_out)
                cands = candidate_map_rows(conn, cik, name, adsh, fdate, rows, members)
                listed = [r for r in rows if r["trading_symbol"] and r["class_member"] in members]
                unlisted = [r for r in rows if not r["trading_symbol"] and r["class_member"] in members]
                flag = " (already mapped; candidates not written)" if cik in already else ""
                print(f"  {cik:>8}  {name[:34]:<34} 10-K {fdate}  listed={len(listed)} "
                      f"unlisted={len(unlisted)} members_on_facts={len(members)}{flag}")
                for r in rows:
                    if r["trading_symbol"] and r["resolved"] == "unresolved":
                        unlisted_report.append(f"{cik} {name}: symbol {r['trading_symbol']} "
                                               f"('{r['security_title']}') could not be matched to "
                                               f"one of {sorted(members)}; not mapped")
                for r in unlisted:
                    unlisted_report.append(f"{cik} {name}: {r['class_member']} "
                                           f"({r['security_title'] or 'no title'}) has no "
                                           f"trading symbol; needs a cited conversion ratio")
                if cik not in already:
                    map_rows_all.extend(cands)

        with open(out_path, "w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["cik", "name", "adsh", "filing_date", "class_member",
                                              "trading_symbol", "exchange", "security_title",
                                              "resolved", "on_share_count_facts"])
            w.writeheader()
            w.writerows(cover_rows_all)
        print(f"\nWrote {out_path} ({len(cover_rows_all)} cover-page class lines)")

        if unlisted_report or REPORT:
            print("\nFor review (NOT mapped):")
            for line in unlisted_report + REPORT:
                print("  " + line)

        print(f"\n{len(map_rows_all)} candidate mapping row(s) for listed classes:")
        for r in map_rows_all:
            print(f"  {r['cik']},{r['class_label']},{r['ticker']},{r['effective_from']},{r['effective_to'] or '-'}")
        if args.write_map and map_rows_all:
            with open(map_path, "a", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=["cik", "class_label", "ticker", "prices_with_ticker",
                                                  "conversion_ratio", "is_excluded", "effective_from",
                                                  "effective_to", "source", "source_note"])
                w.writerows(map_rows_all)
            print(f"Appended {len(map_rows_all)} row(s) to {map_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
