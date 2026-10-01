"""Audit the gross_profit rules: every number the code and docs cite, recomputed.

WHY. The gross-profit tag order, the component variants and their guard
(sql/03_gold/050) were chosen on measurements, and those measurements are
quoted in SQL comments, in concept_formula_variant.notes and in
docs/gold_tables.md. A quoted number nobody can regenerate is how a wrong
one survives: the first version of this work cited 1.7% for a figure that
is 66.0%, from a share computed over the wrong denominator. This tool is
the single place the figures come from, and it also checks that the
database's own resolver returns what an independent re-implementation of
the rule returns.

WHAT IT MEASURES, on non-financial (SIC not 6xxx) annual periods
(qtrs = 4, undimensioned, USD, as first reported, value dates 2011-2025)
that have positive revenue and at least one gross-profit or cost tag:

  A. the tag-order rules, resolved share and agreement with a filed
     GrossProfit within 1% of revenue
  B. CostOfRevenue against CostOfGoodsAndServicesSold where both are filed
  C. the component variants, guarded and unguarded
  D. the rejected excluding-D&A elements
  E. partial-component exposure: a component variant period that also
     files another us-gaap cost-of-revenue element not on the allowlist
  F. implementation: sec_gold.get_canonical(cik, 'gross_profit', ...)
     against this file's own evaluation of the rule, period by period

Read-only: temporary tables only, nothing in sec_data changes.

Run from the repository root:
    uv run python tools/audit_gross_profit.py [--out docs/audits/gross_profit.md]
"""
from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

import pandas as pd
import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dera_pipeline import config  # noqa: E402

COST_TAGS = ["GrossProfit", "CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold",
             "CostOfServices", "CostOfMerchandiseSalesBuyingAndOccupancyCosts",
             "CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization"]
TOL = 0.01

PERIODS_SQL = """
CREATE TEMP TABLE audit_f AS
SELECT n.cik, n.value_date, n.tag, max(n.value) AS value
FROM sec_silver.num_silver n
JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
WHERE n.qtrs = 4 AND n.segments IS NULL AND n.coreg IS NULL AND n.uom = 'USD' AND n.rank_pit = 1
  AND n.value_date BETWEEN DATE '2011-01-01' AND DATE '2025-12-31'
  AND (s.sic IS NULL OR s.sic < 6000 OR s.sic >= 7000)
  AND n.tag = ANY(%(tags)s)
GROUP BY 1, 2, 3;
"""

# The guard, evaluated exactly as sec_gold.custom_line_present does for a
# flow: same period length, positive, undimensioned, as first reported, a
# tag with no us-gaap version, matching the variant's pattern and not its
# exception (read from concept_formula_variant, not restated here).
GUARD_SQL = """
SELECT p.cik, p.value_date, fv.variant,
       EXISTS (
         SELECT 1 FROM sec_silver.num_silver n
         WHERE n.cik = p.cik AND n.value_date = p.value_date AND n.qtrs = 4
           AND n.segments IS NULL AND n.coreg IS NULL AND n.value > 0 AND n.rank_pit = 1
           AND n.tag ~ fv.guard_match AND (fv.guard_except IS NULL OR n.tag !~ fv.guard_except)
           AND NOT EXISTS (SELECT 1 FROM sec_silver.tag_silver t
                            WHERE t.tag = n.tag AND t.version LIKE 'us-gaap%%')
       ) AS guarded
FROM (SELECT DISTINCT cik, value_date FROM audit_f WHERE tag IN ('CostOfGoodsSold', 'CostOfServices')) p
CROSS JOIN sec_gold.concept_formula_variant fv
WHERE fv.concept = 'gross_profit' AND fv.guard_match IS NOT NULL
"""

# Other us-gaap cost-of-revenue elements a component period also files:
# children of CostOfGoodsAndServicesSold / CostOfRevenue in the taxonomy
# that are not on the allowlist and are not D&A.
OTHER_COST_SQL = """
SELECT p.cik, p.value_date, string_agg(DISTINCT n.tag, ' ') AS other_tags
FROM (SELECT DISTINCT cik, value_date FROM audit_f WHERE tag IN ('CostOfGoodsSold', 'CostOfServices')) p
JOIN sec_silver.num_silver n ON n.cik = p.cik AND n.value_date = p.value_date
WHERE n.qtrs = 4 AND n.segments IS NULL AND n.coreg IS NULL AND n.value > 0 AND n.rank_pit = 1
  AND n.tag = ANY(%(children)s)
GROUP BY 1, 2
"""


def share(mask) -> str:
    mask = pd.Series(mask)
    return f"{mask.mean():.1%}" if len(mask) else "n/a"


def within(est, gp, rev) -> pd.Series:
    return ((est - gp).abs() / rev) <= TOL


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--out", default="docs/audits/gross_profit.md")
    args = ap.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    arcs = pd.read_csv(root / "data" / "reference" / "usgaap_cost_calc_arcs.csv")
    allow = {"CostOfRevenue", "CostOfGoodsAndServicesSold", "CostOfGoodsSold", "CostOfServices",
             "CostOfMerchandiseSalesBuyingAndOccupancyCosts"}
    children = sorted(set(arcs[arcs.parent.isin(["CostOfGoodsAndServicesSold", "CostOfRevenue"])].child)
                      - allow - {c for c in arcs.child if "Depreciation" in c or "Amortization" in c})

    with psycopg.connect(config.pg_dsn()) as con, con.cursor() as cur:
        cur.execute(PERIODS_SQL, {"tags": COST_TAGS})
        cur.execute("SELECT cik, value_date, tag, value FROM audit_f")
        f = pd.DataFrame(cur.fetchall(), columns=["cik", "value_date", "tag", "value"])
        p = f.pivot_table(index=["cik", "value_date"], columns="tag", values="value", aggfunc="max").reset_index()
        keys = list(p[["cik", "value_date"]].itertuples(index=False, name=None))
        cur.execute("CREATE TEMP TABLE audit_p (cik INTEGER, value_date DATE)")
        with cur.copy("COPY audit_p FROM STDIN") as cp:
            for k in keys:
                cp.write_row(k)
        cur.execute("""SELECT cik, value_date,
                              sec_gold.resolve_direct(cik, 'revenue', value_date, 4, 'pit'),
                              sec_gold.get_canonical(cik, 'gross_profit', value_date, 4, 'pit'),
                              sec_gold.resolve_direct(cik, 'cost_of_revenue', value_date, 4, 'pit')
                       FROM audit_p""")
        r = pd.DataFrame(cur.fetchall(), columns=["cik", "value_date", "rev", "gp_db", "cor_db"])
        cur.execute(GUARD_SQL)
        g = pd.DataFrame(cur.fetchall(), columns=["cik", "value_date", "variant", "guarded"])
        cur.execute(OTHER_COST_SQL, {"children": children})
        o = pd.DataFrame(cur.fetchall(), columns=["cik", "value_date", "other_tags"])
        cur.execute("SELECT count(*) FROM sec_gold.concept_tag_map")
        tag_rows = cur.fetchone()[0]

    for c in COST_TAGS:
        if c not in p:
            p[c] = float("nan")
    p = p.merge(r, on=["cik", "value_date"])
    for v in (2, 3):
        gv = g[g.variant == v][["cik", "value_date", "guarded"]].rename(columns={"guarded": f"guard{v}"})
        p = p.merge(gv, on=["cik", "value_date"], how="left")
        p[f"guard{v}"] = p[f"guard{v}"].fillna(False).astype(bool)
    p = p.merge(o, on=["cik", "value_date"], how="left")
    num = ["rev", "gp_db", "cor_db"] + COST_TAGS
    p[num] = p[num].astype(float)
    p = p[p.rev > 0].copy()

    gp, rev = p["GrossProfit"], p["rev"]
    cor, cogss = p["CostOfRevenue"], p["CostOfGoodsAndServicesSold"]
    cogs, cos, merch = p["CostOfGoodsSold"], p["CostOfServices"], p["CostOfMerchandiseSalesBuyingAndOccupancyCosts"]
    exda = p["CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization"]
    lines = [f"# Gross profit audit, {dt.date.today().isoformat()}", "",
             "Generated by `tools/audit_gross_profit.py`; do not edit by hand.", "",
             f"Universe: {len(p):,} non-financial annual periods (2011–2025, as first reported) with positive "
             f"revenue and a gross-profit or cost tag; {gp.notna().sum():,} file `GrossProfit`. "
             f"`concept_tag_map` rows: {tag_rows}.", ""]

    # A. tag order
    lines += ["## A. Tag order", "", "| Rule | Resolved | Formula-only periods | Agrees ≤1% | n compared |",
              "|---|---:|---:|---:|---:|"]
    total_old, total_new = cogss.combine_first(cor), cor.combine_first(cogss).combine_first(merch)
    for name, cost in [("CostOfGoodsAndServicesSold, then CostOfRevenue (before)", total_old),
                       ("CostOfRevenue, CostOfGoodsAndServicesSold, merchandise (after)", total_new)]:
        est = rev - cost
        both = gp.notna() & est.notna()
        lines.append(f"| {name} | {share(gp.notna() | est.notna())} | {(gp.isna() & est.notna()).sum():,} | "
                     f"{share(within(est[both], gp[both], rev[both]))} | {both.sum():,} |")
    only_merch = cor.isna() & cogss.isna() & merch.notna()
    lines += ["", f"Periods resolved only by `CostOfMerchandiseSalesBuyingAndOccupancyCosts`: {only_merch.sum():,}.", ""]

    # B. both cost tags
    b = p[cor.notna() & cogss.notna() & gp.notna()]
    same = (b.CostOfRevenue - b.CostOfGoodsAndServicesSold).abs() <= 0.001 * b.CostOfRevenue
    bd = b[~same]
    lines += ["## B. Both cost tags filed beside GrossProfit", "",
              "| Subset | n | revenue − CostOfRevenue ≤1% | revenue − CostOfGoodsAndServicesSold ≤1% |", "|---|---:|---:|---:|",
              f"| all | {len(b):,} | {share(within(b.rev - b.CostOfRevenue, b.GrossProfit, b.rev))} | "
              f"{share(within(b.rev - b.CostOfGoodsAndServicesSold, b.GrossProfit, b.rev))} |",
              f"| the two differ by >0.1% | {len(bd):,} | {share(within(bd.rev - bd.CostOfRevenue, bd.GrossProfit, bd.rev))} | "
              f"{share(within(bd.rev - bd.CostOfGoodsAndServicesSold, bd.GrossProfit, bd.rev))} |", ""]

    # C. component variants
    no_total = cor.isna() & cogss.isna() & merch.isna()
    v2 = no_total & cogs.notna()
    v3 = no_total & cogs.isna() & cos.notna()
    lines += ["## C. Component variants (no cost total filed)", "",
              "| Variant | Test periods (GrossProfit filed) | Unguarded ≤1% | Guarded n | Guarded ≤1% | Blocked n | Blocked ≤1% | Fills without GrossProfit, unguarded → guarded |",
              "|---|---:|---:|---:|---:|---:|---:|---:|"]
    for name, m, est, gcol in [("2: goods (+ services)", v2, rev - cogs - cos.fillna(0), "guard2"),
                               ("2, goods + services only", v2 & cos.notna(), rev - cogs - cos, "guard2"),
                               ("3: services only", v3, rev - cos, "guard3")]:
        t = m & gp.notna()
        ok = within(est, gp, rev)
        kept, blk = t & ~p[gcol], t & p[gcol]
        fill = m & gp.isna()
        lines.append(f"| {name} | {t.sum():,} | {share(ok[t])} | {kept.sum():,} | {share(ok[kept])} | "
                     f"{blk.sum():,} | {share(ok[blk])} | {fill.sum():,} → {(fill & ~p[gcol]).sum():,} |")
    lines.append("")

    # D. excluding D&A
    x = p[exda.notna() & gp.notna() & cor.isna() & cogss.isna()]
    lines += ["## D. Excluding-D&A elements (rejected)", "",
              f"Periods filing `CostOfGoodsAndServiceExcludingDepreciationDepletionAndAmortization` and `GrossProfit` "
              f"but no cost total: {len(x):,}; revenue − it reproduces `GrossProfit` within 1% in "
              f"{share(within(x.rev - x[exda.name], x.GrossProfit, x.rev))}.", ""]

    # E. partial components
    comp = p[v2 | v3]
    partial = comp.other_tags.notna()
    lines += ["## E. Partial-component exposure", "",
              f"Component-variant periods that also file a us-gaap cost-of-revenue element outside the allowlist "
              f"(taxonomy children of `CostOfGoodsAndServicesSold` / `CostOfRevenue`, D&A excluded): "
              f"{partial.sum():,} of {len(comp):,} ({share(partial)}).", ""]
    if partial.any():
        t = comp[partial & comp.GrossProfit.notna()]
        est = t.rev - t.CostOfGoodsSold.fillna(0) - t.CostOfServices.fillna(0)
        lines.append(f"Of those that also file `GrossProfit` ({len(t):,}), the component formula agrees within 1% in "
                     f"{share(within(est, t.GrossProfit, t.rev))}.")
        top = comp[partial].other_tags.str.split().explode().value_counts().head(8)
        lines += ["", "Most common other elements: " + ", ".join(f"`{k}` ({v})" for k, v in top.items()), ""]

    # F. implementation
    expect = gp.copy()
    v1 = rev - total_new
    expect = expect.combine_first(v1)
    e2 = (rev - cogs - cos.fillna(0)).where(v2 & ~p.guard2)
    e3 = (rev - cos).where(v3 & ~p.guard3)
    expect = expect.combine_first(e2).combine_first(e3)
    db = p.gp_db
    agree = (expect.isna() & db.isna()) | ((expect - db).abs() <= 1)
    lines += ["## F. Implementation check", "",
              f"`get_canonical(cik, 'gross_profit', value_date, 4, 'pit')` against this file's evaluation of the rule: "
              f"{agree.sum():,} of {len(p):,} periods identical ({share(agree)}).", ""]
    if (~agree).any():
        bad = p[~agree].assign(expected=expect[~agree])
        lines += ["First disagreements (cik, value_date, expected, database):", ""]
        lines += [f"- {r.cik} {r.value_date} {r.expected:,.0f} {r.gp_db:,.0f}" for r in bad.head(10).itertuples()]
        lines.append("")

    out = root / args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
