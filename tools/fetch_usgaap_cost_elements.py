"""Record what the FASB US-GAAP taxonomy says about the gross-profit elements, every year.

WHY. `gross_profit` resolves from `GrossProfit` or, failing that, from
`revenue - cost_of_revenue`, and `cost_of_revenue` is an allowlist of
tags. Which tags belong on that list, and in what order, is a question
the taxonomy answers authoritatively: its calculation linkbase states
which element sums into which (`CostOfGoodsAndServicesSold` is a child of
`CostOfRevenue`, never the reverse), and its element schema states which
elements existed in a given year. A filer can only have used an element
that was in the taxonomy it filed under, so an element's lifespan also
explains coverage gaps by year. Guessing this from tag names is how a
component ends up ranked above the total it belongs to.

WHAT IS RECORDED. Two files under data/reference/:

    usgaap_cost_elements.csv
        element, first_year, last_year, years -- for every element whose
        name matches the cost / gross-profit / revenue families below, the
        taxonomy years (2009 onward) whose schema declares it.

    usgaap_cost_calc_arcs.csv
        parent, child, weight, first_year, last_year, years -- every
        calculation arc, in any statement-of-income calculation linkbase,
        whose parent or child is in that set. weight is +1 or -1 as the
        taxonomy gives it.

Evidence only, nothing inferred: an arc appears with exactly the years
in which the taxonomy published it.

SOURCE. https://xbrl.fasb.org/us-gaap/<year>/ -- one zip per year,
`us-gaap-<year>-01-31.zip` through 2021 and `us-gaap-<year>.zip` from
2022. Cached under data/taxonomy/ (not tracked); a cached zip is never
re-downloaded.

Run from the repository root:
    uv run python tools/fetch_usgaap_cost_elements.py [--years 2009-2026]
"""
from __future__ import annotations

import argparse
import csv
import io
import re
import sys
import urllib.request
import zipfile
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "data" / "taxonomy"
OUT_ELEMENTS = ROOT / "data" / "reference" / "usgaap_cost_elements.csv"
OUT_ARCS = ROOT / "data" / "reference" / "usgaap_cost_calc_arcs.csv"

# Element families of interest: the gross-profit line, every cost-of-revenue
# element, the single-step totals, and revenue totals.
FAMILY = re.compile(
    r"^(GrossProfit|CostOf\w*|Cost(Direct|sAndExpenses)\w*|CostsAndExpenses|"
    r"OperatingCostsAndExpenses|OtherCostOfOperatingRevenue|ContractRevenueCost|"
    r"RefiningAndMarketingCosts|Revenues?|RevenueFromContractWithCustomer\w*|"
    r"SalesRevenue\w*|ExciseAndSalesTaxes)$"
)
ELEMENT_RE = re.compile(r"<(?:xs:|xsd:)?element\b[^>]*\bname=['\"]([A-Za-z0-9_]+)['\"]")
LOC_RE = re.compile(
    r"<(?:link:)?loc\b[^>]*xlink:href=['\"][^'\"]*#us-gaap_([A-Za-z0-9_]+)['\"][^>]*"
    r"xlink:label=['\"]([^'\"]+)['\"]"
    r"|<(?:link:)?loc\b[^>]*xlink:label=['\"]([^'\"]+)['\"][^>]*"
    r"xlink:href=['\"][^'\"]*#us-gaap_([A-Za-z0-9_]+)['\"]"
)
ARC_RE = re.compile(r"<(?:link:)?calculationArc\b([^>]*)/?>")
ATTR_RE = re.compile(r"(xlink:from|xlink:to|weight)=['\"]([^'\"]+)['\"]")


def taxonomy_url(year: int) -> str:
    """The FASB archive for a taxonomy year (naming changed in 2022)."""
    name = f"us-gaap-{year}.zip" if year >= 2022 else f"us-gaap-{year}-01-31.zip"
    return f"https://xbrl.fasb.org/us-gaap/{year}/{name}"


def parse_elements(xsd_text: str) -> set[str]:
    """Element names declared in a taxonomy schema."""
    return set(ELEMENT_RE.findall(xsd_text))


def parse_calc_arcs(cal_text: str) -> list[tuple[str, str, float]]:
    """(parent, child, weight) for every calculation arc in one linkbase.

    Arcs point at locator labels, not element names, so labels are
    resolved through the file's own locators first.
    """
    label_to_element = {}
    for m in LOC_RE.finditer(cal_text):
        if m.group(1):
            label_to_element[m.group(2)] = m.group(1)
        else:
            label_to_element[m.group(3)] = m.group(4)
    arcs = []
    for m in ARC_RE.finditer(cal_text):
        attrs = dict(ATTR_RE.findall(m.group(1)))
        parent = label_to_element.get(attrs.get("xlink:from", ""))
        child = label_to_element.get(attrs.get("xlink:to", ""))
        if parent and child:
            arcs.append((parent, child, float(attrs.get("weight", "1"))))
    return arcs


def year_span(years: set[int]) -> tuple[int, int, str]:
    """First year, last year, and the years as a compact string."""
    ys = sorted(years)
    return ys[0], ys[-1], " ".join(str(y) for y in ys)


def fetch(year: int) -> bytes:
    CACHE.mkdir(parents=True, exist_ok=True)
    path = CACHE / taxonomy_url(year).rsplit("/", 1)[1]
    if not path.exists():
        req = urllib.request.Request(taxonomy_url(year), headers={"User-Agent": "dera-pipeline research"})
        with urllib.request.urlopen(req, timeout=300) as r:
            path.write_bytes(r.read())
    return path.read_bytes()


def scan(year: int) -> tuple[set[str], list[tuple[str, str, float]]]:
    z = zipfile.ZipFile(io.BytesIO(fetch(year)))
    names = z.namelist()
    # the core schema: elts/us-gaap-<year>[-01-31].xsd
    core = [n for n in names if re.search(r"/elts/us-gaap-\d{4}(-01-31)?\.xsd$", n)]
    elements: set[str] = set()
    for n in core:
        elements |= parse_elements(z.read(n).decode("utf-8", "replace"))
    arcs: list[tuple[str, str, float]] = []
    for n in names:
        if re.search(r"/stm/[^/]*-(soi|is)[^/]*-cal-[^/]*\.xml$", n):
            arcs += parse_calc_arcs(z.read(n).decode("utf-8", "replace"))
    return elements, arcs


def parse_years(text: str) -> list[int]:
    a, _, b = text.partition("-")
    return list(range(int(a), int(b or a) + 1))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--years", default="2009-2026", help="inclusive range, e.g. 2009-2026")
    args = ap.parse_args(argv)

    element_years: dict[str, set[int]] = defaultdict(set)
    arc_years: dict[tuple[str, str, float], set[int]] = defaultdict(set)
    for year in parse_years(args.years):
        try:
            elements, arcs = scan(year)
        except Exception as e:  # a missing year is reported, not fatal
            print(f"{year}: skipped ({e})", file=sys.stderr)
            continue
        fam = {e for e in elements if FAMILY.match(e)}
        for e in fam:
            element_years[e].add(year)
        kept = 0
        for p, c, w in arcs:
            if FAMILY.match(p) or FAMILY.match(c):
                arc_years[(p, c, w)].add(year)
                kept += 1
        print(f"{year}: {len(elements):,} elements, {len(fam)} in family, {kept} family calc arcs")

    with OUT_ELEMENTS.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["element", "first_year", "last_year", "years"])
        for e in sorted(element_years):
            w.writerow([e, *year_span(element_years[e])])
    with OUT_ARCS.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["parent", "child", "weight", "first_year", "last_year", "years"])
        for (p, c, wt) in sorted(arc_years):
            w.writerow([p, c, int(wt), *year_span(arc_years[(p, c, wt)])])
    print(f"wrote {OUT_ELEMENTS.relative_to(ROOT)} ({len(element_years)} elements), "
          f"{OUT_ARCS.relative_to(ROOT)} ({len(arc_years)} arcs)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
