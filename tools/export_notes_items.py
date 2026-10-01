"""Export Compustat-style pension, segment and customer files from footnote facts.

Reads data/exports/notes/notes_facts.parquet (tools/extract_notes_facts.py)
and applies dera_pipeline/notes_items.py. Only annual reports (10-K,
10-K/A, 10-KT, 10-KT/A) count, and only facts dated at the report's own
fiscal period end; for each company and fiscal period end the first
accepted report wins (as first reported, like the quarterly export).
Amounts are in millions of dollars, as Compustat.

OUTPUT, under data/exports/compustat/:

    pensions.parquet   cik, datadate, pplao, pbpro (+ rule_pplao, rule_pbpro), funded_status
                       (the plan's own funded-status fact by the same rule, for the audit),
                       paddml, pcupsu, pbnaa, pbnvv, pbpru, pplau (all null:
                       see docs/compustat_items.md), adsh, accepted
    segments.parquet   cik, datadate, stype ("BUSSEG"), sid, snms, member,
                       sales, sales_tag, sics1, naicsh, srcdate, adsh, accepted
    customers.parquet  cik, datadate, cnms, member, ctype, salecs, adsh, accepted
    notes_items_coverage.csv   companies and fiscal years per file and year

Run from the repository root:
    uv run python tools/export_notes_items.py
"""
from __future__ import annotations

import sys
from pathlib import Path

import polars as pl

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from dera_pipeline import notes_items as ni  # noqa: E402

FACTS = ROOT / "data" / "exports" / "notes" / "notes_facts.parquet"
OUT = ROOT / "data" / "exports" / "compustat"
ANNUAL_FORMS = ["10-K", "10-K/A", "10-KT", "10-KT/A"]
FVPA, PBO = "DefinedBenefitPlanFairValueOfPlanAssets", "DefinedBenefitPlanBenefitObligation"
FUNDED = "DefinedBenefitPlanFundedStatusOfPlan"
ITEM = {FVPA: "pplao", PBO: "pbpro", FUNDED: "funded_status"}
# Compustat segment SALES is sales to outside customers; total segment revenue tags follow
SALES_PRIORITY = ["SegmentReportingInformationRevenueFromExternalCustomers", "RevenueFromExternalCustomers",
                  "Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax", "SalesRevenueNet",
                  "RevenueFromContractWithCustomerIncludingAssessedTax", "SegmentReportingInformationRevenue",
                  "RevenuesNetOfInterestExpense", "SalesRevenueGoodsNet", "SalesRevenueServicesNet"]
REVENUE_SEGMENT = r"^BusinessSegments=[^;]+;(ConsolidationItems=OperatingSegments;)?$"


def annual(facts: pl.DataFrame) -> pl.DataFrame:
    """Facts at the fiscal period end of the first accepted annual report per company-period."""
    f = facts.filter(pl.col("form").is_in(ANNUAL_FORMS) & (pl.col("iprx") == 0)
                     & (pl.col("ddate") == pl.col("period").str.to_date("%Y%m%d")))
    first = (f.select("cik", "ddate", "adsh", "accepted").unique()
             .sort("accepted").unique(["cik", "ddate"], keep="first").select("adsh"))
    return f.join(first, on="adsh")


def pensions(f: pl.DataFrame) -> pl.DataFrame:
    p = f.filter((pl.col("kind") == "pension") & pl.col("tag").is_in(list(ITEM)) & (pl.col("qtrs") == 0)
                 & (pl.col("uom") == "USD"))
    p = p.with_columns(scope=pl.col("segments").map_elements(ni.pension_scope, return_dtype=pl.Utf8))
    rows = []
    for (adsh, tag), g in p.group_by(["adsh", "tag"]):
        vals = {s: v for s, v in g.filter(pl.col("scope").is_in(["none", "total", "domestic", "foreign"]))
                .group_by("scope").agg(pl.col("value").first()).iter_rows()}
        typed = g.filter(pl.col("scope").is_in(["total", "domestic", "foreign", "opeb", "plan_other"])).height > 0
        value, rule = ni.select_pension(vals, typed)
        if value is not None:
            r = g.row(0, named=True)
            rows.append({"cik": r["cik"], "datadate": r["ddate"], "adsh": adsh, "accepted": r["accepted"],
                         "tag": tag, "value": value / 1e6, "rule": rule})
    if not rows:
        return pl.DataFrame()
    long = pl.DataFrame(rows)
    wide = (long.with_columns(item=pl.col("tag").replace_strict(ITEM))
            .pivot(on="item", index=["cik", "datadate", "adsh", "accepted"], values=["value", "rule"]))
    wide = wide.rename({f"value_{i}": i for i in ITEM.values() if f"value_{i}" in wide.columns})
    for c in ["pplao", "pbpro", "funded_status", "rule_pplao", "rule_pbpro", "rule_funded_status"]:
        if c not in wide.columns:
            wide = wide.with_columns(pl.lit(None).alias(c))
    # S&P: pcupsu is Not Available for SFAS 87 adopters; paddml ended with SFAS 158 (2006); the four
    # over/underfunded splits ended with SFAS 132 (1998). None exists in the SEC era (2009 on).
    nulls = [pl.lit(None, pl.Float64).alias(c) for c in ["paddml", "pcupsu", "pbnaa", "pbnvv", "pbpru", "pplau"]]
    return wide.with_columns(nulls).select(
        "cik", "datadate", "pplao", "pbpro", "rule_pplao", "rule_pbpro", "funded_status", "rule_funded_status", "paddml", "pcupsu", "pbnaa", "pbnvv",
        "pbpru", "pplau", "adsh", "accepted").sort("cik", "datadate")


def segments(f: pl.DataFrame) -> pl.DataFrame:
    s = f.filter((pl.col("kind") == "segment") & (pl.col("qtrs") == 4) & (pl.col("uom") == "USD")
                 & pl.col("segments").str.contains(REVENUE_SEGMENT))
    s = s.with_columns(member=pl.col("segments").str.extract(r"^BusinessSegments=([^;]+);"),
                       pri=pl.col("tag").replace_strict(SALES_PRIORITY, list(range(len(SALES_PRIORITY))),
                                                        default=99),
                       opseg=pl.col("segments").str.contains("ConsolidationItems="))
    # one value per report and segment: the highest-priority tag, the plain member before the
    # operating-segments variant of the same fact
    s = s.sort("pri", "opseg").unique(["adsh", "member"], keep="first")
    s = s.with_columns(snms=pl.col("member").map_elements(ni.camel_words, return_dtype=pl.Utf8))
    codes = s["snms"].map_elements(lambda n: list(ni.sin_codes(n)), return_dtype=pl.List(pl.Int64))
    s = s.with_columns(sics1=codes.list.get(0), naicsh=codes.list.get(1))
    s = s.with_columns(sid=pl.col("member").rank("dense").over("cik").cast(pl.Int64))
    return s.select("cik", pl.col("ddate").alias("datadate"), pl.lit("BUSSEG").alias("stype"), "sid", "snms", "member",
                    (pl.col("value") / 1e6).alias("sales"), pl.col("tag").alias("sales_tag"), "sics1", "naicsh",
                    pl.col("filed").alias("srcdate"), "adsh", "accepted").sort("cik", "datadate", "sid")


def customers(f: pl.DataFrame) -> pl.DataFrame:
    c = f.filter(pl.col("kind") == "customer").with_columns(
        member=pl.col("segments").str.extract(r"(?:^|;)MajorCustomers=([^;]+);"))
    rev = (c.filter(pl.col("tag").is_in(SALES_PRIORITY) & (pl.col("qtrs") == 4) & (pl.col("uom") == "USD"))
           .group_by("adsh", "member").agg((pl.col("value").max() / 1e6).alias("salecs")))
    one = c.select("cik", "ddate", "adsh", "accepted", "member").unique(["adsh", "member"])
    one = one.join(rev, on=["adsh", "member"], how="left")
    one = one.with_columns(cnms=pl.col("member").map_elements(ni.camel_words, return_dtype=pl.Utf8))
    one = one.with_columns(ctype=pl.col("cnms").map_elements(ni.customer_type, return_dtype=pl.Utf8))
    return one.select("cik", pl.col("ddate").alias("datadate"), "cnms", "member", "ctype", "salecs", "adsh",
                      "accepted").sort("cik", "datadate", "cnms")


def write(df: pl.DataFrame, name: str) -> None:
    tmp = OUT / f"{name}.partial"
    df.write_parquet(tmp)
    tmp.rename(OUT / f"{name}.parquet")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    f = annual(pl.read_parquet(FACTS))
    out = {"pensions": pensions(f), "segments": segments(f), "customers": customers(f)}
    cov = []
    for name, df in out.items():
        write(df, name)
        print(f"{name}.parquet: {df.height:,} rows, {df['cik'].n_unique():,} companies")
        cov.append(df.group_by(pl.col("datadate").dt.year().alias("fiscal_year_end"))
                   .agg(pl.col("cik").n_unique().alias("companies"), pl.len().alias("rows"))
                   .with_columns(file=pl.lit(name)))
    pl.concat(cov).sort("file", "fiscal_year_end").write_csv(OUT / "notes_items_coverage.csv")
    p = out["pensions"]
    if p.height:
        print("pension rules:", dict(p.group_by("rule_pbpro").len().iter_rows()))
        k = p.drop_nulls(["pplao", "pbpro", "funded_status"])
        ok = ((k["pplao"] - k["pbpro"] - k["funded_status"]).abs() <= 0.01 * k["pbpro"].abs() + 0.5).sum()
        print(f"funded status = plan assets - PBO (within 1% of PBO) in {ok:,} of {k.height:,} reports")
    c = out["customers"]
    print("customer types:", dict(c.group_by("ctype").len().iter_rows()))
    print("sin segments:", out["segments"].filter(pl.col("sics1").is_not_null() | pl.col("naicsh").is_not_null())
          ["cik"].n_unique(), "companies")


if __name__ == "__main__":
    main()
