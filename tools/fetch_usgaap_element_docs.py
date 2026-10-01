"""Record the FASB definition and calculation context of US-GAAP elements.

WHY. Mapping a research variable (a Compustat item, say "debt in current
liabilities") to XBRL tags is a judgement about meaning, and the taxonomy
states the meaning: each element has a standard label, a documentation
definition, a period type (instant = balance, duration = flow), a
debit/credit balance, and a place in the statement calculation trees
(which elements sum into it, and what it sums into). Choosing tags from
those, rather than from what a tag name sounds like, is what keeps a
mapping from absorbing a component as if it were the total or a
neighbouring concept as if it were the same one.

WHAT IS RECORDED. data/reference/usgaap_element_docs.csv, one row per
element: the taxonomy year the row is read from (the newest that declares
the element, so a retired element is still described), its label,
documentation, period type, balance, data type, and its calculation parents
and children with weights from every statement calculation linkbase of
that year (balance sheet sfp-*, income statement soi-*, cash flows scf-*,
equity sheci-*, comprehensive income soc-*).

WHICH ELEMENTS. The union of
  - every tag in data/reference/compustat_item_map.csv (so every mapped tag
    is always described),
  - every element named in --elements (one per line), and
  - every descendant, to --depth levels, of the statement roots below in
    that year's calculation linkbases,
so the candidates for a mapping come from the taxonomy's own structure.

SOURCE. The archives tools/fetch_usgaap_cost_elements.py caches under
data/taxonomy/ (it downloads any that are missing).

Run from the repository root:
    uv run python tools/fetch_usgaap_element_docs.py [--elements FILE] [--depth 3]
"""
from __future__ import annotations

import argparse
import csv
import io
import re
import sys
import zipfile
from collections import defaultdict
from pathlib import Path
from xml.etree import ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fetch_usgaap_cost_elements as fuce  # noqa: E402  (archive cache and arc parser)

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "data" / "reference" / "usgaap_element_docs.csv"
YEARS = list(range(2026, 2010, -1))  # newest first
ROOTS = [
    "Assets", "AssetsCurrent", "AssetsNoncurrent", "Liabilities", "LiabilitiesCurrent", "LiabilitiesNoncurrent",
    "LiabilitiesAndStockholdersEquity", "StockholdersEquity",
    "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest",
    "Revenues", "CostsAndExpenses", "OperatingExpenses", "OperatingIncomeLoss", "NetIncomeLoss", "ProfitLoss",
    "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
    "IncomeTaxExpenseBenefit", "NonoperatingIncomeExpense",
    "NetCashProvidedByUsedInOperatingActivities", "NetCashProvidedByUsedInInvestingActivities",
    "NetCashProvidedByUsedInFinancingActivities",
]
NS = {"link": "http://www.xbrl.org/2003/linkbase", "xlink": "http://www.w3.org/1999/xlink",
      "xs": "http://www.w3.org/2001/XMLSchema", "xbrli": "http://www.xbrl.org/2003/instance"}
XL = "{http://www.w3.org/1999/xlink}"
STATEMENT = re.compile(r"/stm/[^/]*-(sfp|soi|scf|sheci|soc)[^/]*-cal-[^/]*\.xml$")
DOC_ROLE = "http://www.xbrl.org/2003/role/documentation"
LABEL_ROLE = "http://www.xbrl.org/2003/role/label"


def parse_schema(xsd: bytes) -> dict[str, dict]:
    """Element name -> period type, balance, data type, abstract."""
    out = {}
    for el in ET.fromstring(xsd).iter("{http://www.w3.org/2001/XMLSchema}element"):
        name = el.get("name")
        if not name:
            continue
        out[name] = {
            "period_type": el.get("{http://www.xbrl.org/2003/instance}periodType", ""),
            "balance": el.get("{http://www.xbrl.org/2003/instance}balance", ""),
            "data_type": el.get("type", ""),
            "abstract": el.get("abstract", "false"),
        }
    return out


def parse_labels(xml: bytes, role: str) -> dict[str, str]:
    """Element name -> label text of one role, resolved through locators and arcs."""
    root = ET.fromstring(xml)
    loc = {}
    for lk in root.iter(f"{{{NS['link']}}}labelLink"):
        for locator in lk.iter(f"{{{NS['link']}}}loc"):
            href = locator.get(f"{XL}href", "")
            if "#us-gaap_" in href:
                loc[locator.get(f"{XL}label")] = href.split("#us-gaap_", 1)[1]
        res = {}
        for r in lk.iter(f"{{{NS['link']}}}label"):
            if r.get(f"{XL}role") == role:
                res[r.get(f"{XL}label")] = (r.text or "").strip()
        out = {}
        for a in lk.iter(f"{{{NS['link']}}}labelArc"):
            frm, to = a.get(f"{XL}from"), a.get(f"{XL}to")
            if frm in loc and to in res:
                out[loc[frm]] = res[to]
        return out
    return {}


def descendants(children: dict[str, list[str]], roots: list[str], depth: int) -> set[str]:
    seen, frontier = set(roots), list(roots)
    for _ in range(depth):
        nxt = []
        for p in frontier:
            for c in children.get(p, []):
                if c not in seen:
                    seen.add(c)
                    nxt.append(c)
        frontier = nxt
    return seen


def load_year(year: int):
    z = zipfile.ZipFile(io.BytesIO(fuce.fetch(year)))
    names = z.namelist()
    def one(pattern):
        m = [n for n in names if re.search(pattern, n)]
        return z.read(m[0]) if m else None
    schema = parse_schema(one(r"/elts/us-gaap-\d{4}(-01-31)?\.xsd$"))
    doc_xml = one(r"/elts/us-gaap-doc-\d{4}(-01-31)?\.xml$")
    lab_xml = one(r"/elts/us-gaap-lab-\d{4}(-01-31)?\.xml$")
    docs = parse_labels(doc_xml, DOC_ROLE) if doc_xml else {}
    labels = parse_labels(lab_xml, LABEL_ROLE) if lab_xml else {}
    if not docs and lab_xml:  # older years keep documentation inside the label file
        docs = parse_labels(lab_xml, DOC_ROLE)
    arcs = []
    for n in names:
        m = STATEMENT.search(n)
        if m:
            for p, c, w in fuce.parse_calc_arcs(z.read(n).decode("utf-8", "replace")):
                arcs.append((p, c, w, m.group(1)))
    return schema, labels, docs, arcs


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--elements", help="file with one element name per line")
    ap.add_argument("--depth", type=int, default=3)
    args = ap.parse_args(argv)
    wanted = set()
    item_map = ROOT / "data" / "reference" / "compustat_item_map.csv"
    if item_map.exists():
        with item_map.open() as f:
            for r in csv.DictReader(f):
                if r["rule"] == "tag":
                    wanted.add(r["term"])
                elif r["term"].startswith("tag:"):
                    wanted.add(r["term"][4:])
    if args.elements:
        wanted = {line.strip() for line in Path(args.elements).read_text().splitlines() if line.strip()}

    newest = load_year(YEARS[0])
    children = defaultdict(list)
    for p, c, _w, _s in newest[3]:
        children[p].append(c)
    wanted |= descendants(children, ROOTS, args.depth)

    rows, remaining = {}, set(wanted)
    for year in YEARS:
        if not remaining:
            break
        try:
            schema, labels, docs, arcs = newest if year == YEARS[0] else load_year(year)
        except Exception as e:
            print(f"{year}: skipped ({e})", file=sys.stderr)
            continue
        par, chi = defaultdict(set), defaultdict(set)
        for p, c, w, s in arcs:
            par[c].add(f"{p}:{int(w):+d}:{s}")
            chi[p].add(f"{c}:{int(w):+d}:{s}")
        for e in sorted(remaining & set(schema)):
            rows[e] = {"element": e, "year": year, "label": labels.get(e, ""), "documentation": docs.get(e, ""),
                       **schema[e], "calc_parents": " ".join(sorted(par[e])), "calc_children": " ".join(sorted(chi[e]))}
        remaining -= set(schema)
        print(f"{year}: {len(rows)} described, {len(remaining)} not yet found")

    with OUT.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["element", "year", "label", "documentation", "period_type", "balance",
                                          "data_type", "abstract", "calc_parents", "calc_children"])
        w.writeheader()
        for e in sorted(rows):
            w.writerow(rows[e])
    if remaining:
        print("not in any taxonomy 2011-2026:", " ".join(sorted(remaining)))
    print(f"wrote {OUT.relative_to(ROOT)} ({len(rows)} elements)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
