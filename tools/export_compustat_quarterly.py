"""Export Compustat-style quarterly items from sec_data.

WHY. Some published predictors use Compustat's quarterly file (ATQ, IBQ, RDQ,
CAPXY, ...). This builds it from sec_gold.fact_asof by the same cited map as
tools/export_compustat.py: each quarterly item in
data/reference/compustat_quarterly_items.csv is its annual base item resolved
from facts of the right duration.

HOW
  - Quarter ends: every value_date with a three-month fact, plus the fiscal
    year ends (value_dates with a four-quarter 10-K fact).
  - Fiscal quarter (fqtr): from the company's next fiscal year end, which a
    quarter end precedes by 0, 3, 6 or 9 months; after the last known year end
    the year-end month repeats. fyearq follows Compustat's fyear rule on that
    year end.
  - kind instant: the base item from balances at the quarter end.
  - kind quarter: from three-month facts; the fourth quarter, which a 10-K does
    not tag, is the year less the nine months to the third quarter end, tag by
    tag (not for per-share items, which do not add across quarters).
  - kind ytd: from the fact whose duration is the fiscal quarter number.
  - avail and rdq: the first NYSE session, on or after the quarter end, that
    a 10-Q or 10-K carrying the quarter's balance sheet or own-period flows was
    tradable. Every value is the one known at rdq: facts first reported later
    (a comparative in next year's filing) are excluded, as are facts dated
    tradable before the quarter ended (mis-dated). Later vintages are not
    followed (the annual export does follow them).
  - share counts (weighted average shares) in Q4 are the year's average, not
    the year less nine months.

UNITS as Compustat: millions; per-share items in dollars.

Read-only against sec_data. Run from the repository root:
    uv run python tools/export_compustat_quarterly.py [--refresh]
Writes data/exports/compustat/quarterly.parquet (not tracked).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
import polars as pl

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from export_compustat import NONNEG, OUT, PER_SHARE, copy_out, fyear, refused_facts  # noqa: E402

from dera_pipeline import compustat  # noqa: E402

FACTS_SQL = """
COPY (
  SELECT f.cik, f.tag, f.value_date, f.qtrs, f.value, f.tradable_from, (f.form LIKE '10-K%%') AS is_10k, f.adsh
  FROM sec_gold.fact_asof f
  WHERE f.tag = ANY(%s) AND f.qtrs IN (0, 1, 2, 3, 4) AND f.uom IN ('USD', 'shares')
    AND (f.form LIKE '10-K%%' OR f.form LIKE '10-Q%%')
) TO STDOUT WITH (FORMAT csv, HEADER)
"""


PRES_SQL = """
COPY (SELECT p.adsh, p.report, p.line, p.stmt, p.tag, p.plabel FROM sec_silver.pre_silver p
      WHERE p.adsh = ANY(%s) AND p.tag = ANY(%s))
TO STDOUT WITH (FORMAT csv, HEADER)
"""


def closure(items, names):
    """Items needed to resolve `names`, including the items their formulas use."""
    seen, stack = set(), list(names)
    while stack:
        n = stack.pop()
        if n in seen:
            continue
        seen.add(n)
        stack += list(items[n].dependencies())
    return {n: items[n] for n in seen}


def resolve(frame: pl.DataFrame, items, base: str) -> pd.Series:
    """Resolve one base item from a wide (cik, datadate) x tag frame."""
    pdf = frame.to_pandas()
    sub = closure(items, [base])
    tags = sorted(set().union(*(i.tags_used() for i in sub.values())))
    res = compustat.resolve_frame(pdf.reindex(columns=tags), sub)
    return pd.Series(res[base].values, index=pd.MultiIndex.from_frame(pdf[["cik", "datadate"]]))


def wide(facts: pl.DataFrame) -> pl.DataFrame:
    return facts.pivot(on="tag", index=["cik", "datadate"], values="value", aggregate_function="first")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--refresh", action="store_true")
    args = ap.parse_args(argv)
    items = compustat.load_map()
    qitems = compustat.load_quarterly()
    need = closure(items, [q["base_item"] for q in qitems])
    tags = sorted(set().union(*(i.tags_used() for i in need.values()),
                              *(r["components"] for r in compustat.load_presentation_rules() if r["rule"] == "refuse_tag")))
    OUT.mkdir(parents=True, exist_ok=True)
    csv_path, tags_txt = OUT / "facts_quarterly.csv", OUT / "facts_quarterly.tags"
    stale = not tags_txt.exists() or tags_txt.read_text().split() != tags
    if args.refresh or not csv_path.exists() or stale:
        print(f"reading {len(tags)} tags (qtrs 0-4) from sec_gold.fact_asof ...", flush=True)
        copy_out(FACTS_SQL, csv_path, (tags,))
        tags_txt.write_text("\n".join(tags))
    f = pl.read_csv(csv_path, try_parse_dates=True, schema_overrides={"value": pl.Float64, "is_10k": pl.String})
    f = f.with_columns(is_10k=pl.col("is_10k") == "t")
    rules = [r for r in compustat.load_presentation_rules() if r["rule"] == "refuse_tag"]
    pres_csv = OUT / "presentation_quarterly.csv"
    if args.refresh or not pres_csv.exists() or stale:
        copy_out(PRES_SQL, pres_csv, (sorted(f["adsh"].unique().to_list()),
                                      sorted({r["tag"] for r in rules} | set().union(*(r["components"] for r in rules)))))
    f = refused_facts(f, pl.read_csv(pres_csv, schema_overrides={"plabel": pl.String, "tag": pl.String}), rules)
    # first-reported value of each fact
    f = f.sort("tradable_from").unique(["cik", "tag", "value_date", "qtrs"], keep="first")
    print(f"{f.height:,} first-reported facts", flush=True)

    fye = f.filter((pl.col("qtrs") == 4) & pl.col("is_10k")).select("cik", pl.col("value_date").alias("fye")).unique()
    qends = pl.concat([f.filter(pl.col("qtrs") == 1).select("cik", "value_date"),
                       fye.rename({"fye": "value_date"})]).unique().sort(["cik", "value_date"])
    # next fiscal year end on or after the quarter end (within a year); else last year end + whole years
    q = qends.join_asof(fye.sort("fye"), left_on="value_date", right_on="fye", by="cik", strategy="forward")
    q = q.with_columns(fye=pl.when((pl.col("fye") - pl.col("value_date")).dt.total_days() <= 370).then(pl.col("fye")))
    last = fye.group_by("cik").agg(pl.col("fye").max().alias("last_fye"))
    q = q.join(last, on="cik", how="left").with_columns(
        fye=pl.coalesce("fye", pl.col("last_fye").dt.offset_by(
            ((pl.col("value_date").dt.year() - pl.col("last_fye").dt.year() +
              (pl.col("value_date").dt.month() > pl.col("last_fye").dt.month()).cast(pl.Int32)).cast(pl.String) + "y"))))
    months = ((pl.col("fye").dt.year() - pl.col("value_date").dt.year()) * 12
              + pl.col("fye").dt.month() - pl.col("value_date").dt.month())
    q = q.with_columns(fqtr=(4 - (months / 3).round(0)).cast(pl.Int32)).filter(pl.col("fqtr").is_between(1, 4))
    q = q.with_columns(fyearq=fyear(pl.col("fye"))).rename({"value_date": "datadate"}).select("cik", "datadate", "fqtr", "fyearq")

    f = f.rename({"value_date": "datadate"})
    # Point in time. A quarter's report date (rdq) is the first 10-Q/10-K tradable on or after the quarter
    # end that carries its balance sheet or its own-period flows (three months, or the year for Q4). Only
    # facts tradable by then count: a value first reported in a later filing (next year's comparative) is
    # not known at rdq, and a fact tradable before the quarter even ended is mis-dated and dropped.
    f = f.filter(pl.col("tradable_from") >= pl.col("datadate"))
    own = pl.concat([f.filter(pl.col("qtrs") == 0), f.filter(pl.col("qtrs") == 1), f.filter(pl.col("qtrs") == 4)])
    rdq = own.join(q.select("cik", "datadate"), on=["cik", "datadate"]).group_by("cik", "datadate").agg(
        rdq=pl.col("tradable_from").min())
    f = f.join(rdq, on=["cik", "datadate"], how="left")
    known = f.filter(pl.col("tradable_from") <= pl.col("rdq"))
    later = f.height - known.height
    f = known.drop("rdq")
    print(f"{later:,} facts first reported after their quarter's report date excluded", flush=True)
    inst = f.filter(pl.col("qtrs") == 0).join(q.select("cik", "datadate"), on=["cik", "datadate"])
    q1 = f.filter(pl.col("qtrs") == 1).join(q.select("cik", "datadate"), on=["cik", "datadate"])
    # fourth quarter = year less nine months, tag by tag
    q4 = q.filter(pl.col("fqtr") == 4).select("cik", "datadate")
    yr = f.filter(pl.col("qtrs") == 4).join(q4, on=["cik", "datadate"])
    q3 = q.filter(pl.col("fqtr") == 3).select("cik", pl.col("datadate").alias("q3"))
    ytd9 = f.filter(pl.col("qtrs") == 3).rename({"datadate": "q3"}).join(q3, on=["cik", "q3"])
    yr = yr.join_asof(ytd9.sort("q3").select("cik", "tag", "q3", pl.col("value").alias("v9"), pl.col("tradable_from").alias("tf9")),
                      left_on="datadate", right_on="q3", by=["cik", "tag"], strategy="backward")
    yr = yr.filter((pl.col("datadate") - pl.col("q3")).dt.total_days().is_between(80, 100))
    # share counts are averages, not sums: Q4 weighted shares are not the year less nine months (that gave
    # Apple -48 million); the year's weighted average stands in for the fourth quarter's
    share_tags = items["_cshpr"].tags_used()
    q4f = yr.with_columns(value=pl.when(pl.col("tag").is_in(sorted(share_tags))).then(pl.col("value"))
                          .otherwise(pl.col("value") - pl.col("v9"))).select(q1.columns)
    qflow = pl.concat([q1, q4f.join(q1.select("cik", "datadate", "tag"), on=["cik", "datadate", "tag"], how="anti")])
    ytd = f.filter(pl.col("qtrs").is_between(1, 4)).join(q, on=["cik", "datadate"]).filter(pl.col("qtrs") == pl.col("fqtr")).select(f.columns)

    out = q.join(rdq.rename({"rdq": "avail"}), on=["cik", "datadate"], how="left").to_pandas().set_index(["cik", "datadate"])
    src = {"instant": wide(inst), "quarter": wide(qflow), "ytd": wide(ytd)}
    comps = set().union(*(r["components"] for r in rules))
    for k in ("quarter", "ytd"):
        fr = src[k].to_pandas()
        inc = compustat.revenues_include_nonoperating(fr, comps)
        fr.loc[inc, "Revenues"] = float("nan")
        src[k] = pl.from_pandas(fr)
        print(f"{k}: Revenues refused in {int(inc.sum()):,} quarters where it equals sales plus non-operating income")
    eps_q1 = wide(q1)
    for qi in qitems:
        frame = eps_q1 if (qi["kind"] == "quarter" and qi["base_item"] in PER_SHARE) else src[qi["kind"]]
        s = resolve(frame, items, qi["base_item"])
        if qi["base_item"] not in PER_SHARE:
            s = s / 1e6
        if qi["base_item"] in NONNEG:
            s = s.abs()
        out[qi["item"]] = s.reindex(out.index)
    out["rdq"] = out["avail"]
    res = pl.from_pandas(out.reset_index())
    res.write_parquet(OUT / "quarterly.parquet")
    cov = res.select([pl.col(c["item"]).is_not_null().mean().alias(c["item"]) for c in qitems]).row(0, named=True)
    print(f"wrote quarterly.parquet: {res.height:,} company-quarters, {res['cik'].n_unique():,} companies; coverage: "
          + ", ".join(f"{k} {v:.0%}" for k, v in cov.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
