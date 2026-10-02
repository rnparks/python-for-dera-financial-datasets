"""Export Compustat-style pension, segment and customer files from footnote facts.

Reads data/exports/notes/notes_facts.parquet (tools/extract_notes_facts.py)
and applies dera_pipeline/notes_items.py. Only annual reports (10-K,
10-K/A, 10-KT, 10-KT/A) count, and only facts dated at the report's own
fiscal period end; for each company and fiscal period end the first
accepted report wins (as first reported, like the quarterly export).
Amounts are in millions of dollars, as Compustat.

OUTPUT, under data/exports/compustat/:

    pensions.parquet   cik, datadate, pplao, pbpro, rule (the one both share), funded_status
                       (the plan's own funded-status fact by the same rule, for the audit),
                       paddml, pcupsu, pbnaa, pbnvv, pbpru, pplau (all null:
                       see docs/compustat_items.md), adsh, accepted
    segments.parquet   cik, datadate, stype ("BUSSEG"), sid, snms, member,
                       sales, sales_tag, sics1, naicsh, srcdate, adsh, accepted
    customers.parquet  cik, datadate, cnms, member, ctype, salecs, adsh, accepted
    aoci.parquet       cik, datadate, recta, msa (+ rule_recta, rule_msa), adsh, accepted
    footnote_items.parquet  cik, datadate, xad (AdvertisingExpense, else MarketingAndAdvertisingExpense,
                       four quarters), ppegt (PropertyPlantAndEquipmentGross), adsh, accepted
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
    """Facts with a value (nil facts dropped) at the fiscal period end of the first accepted annual
    report per company-period."""
    f = facts.filter(pl.col("form").is_in(ANNUAL_FORMS) & (pl.col("iprx") == 0) & pl.col("value").is_not_null()
                     & (pl.col("ddate") == pl.col("period").str.to_date("%Y%m%d")))
    first = (f.select("cik", "ddate", "adsh", "accepted").unique()
             .sort("accepted").unique(["cik", "ddate"], keep="first").select("adsh"))
    return f.join(first, on="adsh")


def pensions(f: pl.DataFrame) -> pl.DataFrame:
    p = f.filter((pl.col("kind") == "pension") & pl.col("tag").is_in(list(ITEM)) & (pl.col("qtrs") == 0)
                 & (pl.col("uom") == "USD"))
    p = p.with_columns(scope=pl.col("segments").map_elements(ni.pension_scope, return_dtype=pl.Utf8))
    rows = []
    for adsh, g in p.group_by("adsh"):
        cand = {}
        for tag, item in ITEM.items():
            t = g.filter(pl.col("tag") == tag)
            vals = {s: v for s, v in t.filter(pl.col("scope").is_in(["none", "total", "domestic", "foreign"]))
                    .group_by("scope").agg(pl.col("value").first()).iter_rows()}
            typed = t.filter(pl.col("scope").is_in(["opeb", "plan_other"])).height > 0
            cand[item] = ni.pension_candidates(vals, typed)
        rule = ni.common_rule(cand["pplao"], cand["pbpro"])
        if not rule:
            continue
        r = g.row(0, named=True)
        fs_rule = rule if rule in cand["funded_status"] else ""
        rows.append({"cik": r["cik"], "datadate": r["ddate"], "adsh": adsh[0] if isinstance(adsh, tuple) else adsh,
                     "accepted": r["accepted"], "pplao": cand["pplao"][rule] / 1e6, "pbpro": cand["pbpro"][rule] / 1e6,
                     "rule": rule, "funded_status": cand["funded_status"][rule] / 1e6 if fs_rule else None})
    if not rows:
        return pl.DataFrame()
    wide = pl.DataFrame(rows, schema_overrides={"funded_status": pl.Float64})
    # S&P: pcupsu is Not Available for SFAS 87 adopters; paddml ended with SFAS 158 (2006); the four
    # over/underfunded splits ended with SFAS 132 (1998). None exists in the SEC era (2009 on).
    nulls = [pl.lit(None, pl.Float64).alias(c) for c in ["paddml", "pcupsu", "pbnaa", "pbnvv", "pbpru", "pplau"]]
    return wide.with_columns(nulls).select(
        "cik", "datadate", "pplao", "pbpro", "rule", "funded_status", "paddml", "pcupsu", "pbnaa", "pbnvv",
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


def aoci(f: pl.DataFrame) -> pl.DataFrame:
    a = f.filter((pl.col("kind") == "aoci") & (pl.col("qtrs") == 0) & (pl.col("uom") == "USD"))
    comp = [ni.aoci_component(t, s) for t, s in zip(a["tag"], a["segments"])]
    a = a.with_columns(item=pl.Series([c[0] for c in comp], dtype=pl.Utf8),
                       rule=pl.Series([c[1] for c in comp], dtype=pl.Utf8)).filter(pl.col("item").is_not_null())
    # the component's own element before the axis member
    a = a.sort(pl.col("rule") != "element").unique(["adsh", "item"], keep="first")
    wide = a.with_columns(value=pl.col("value") / 1e6).pivot(
        on="item", index=["cik", "ddate", "adsh", "accepted"], values=["value", "rule"])
    wide = wide.rename({c: c.removeprefix("value_") for c in wide.columns if c.startswith("value_")})
    for c in ["recta", "msa", "rule_recta", "rule_msa"]:
        if c not in wide.columns:
            wide = wide.with_columns(pl.lit(None).alias(c))
    return wide.select("cik", pl.col("ddate").alias("datadate"), "recta", "msa", "rule_recta", "rule_msa", "adsh",
                       "accepted").sort("cik", "datadate")


def footnote_items(f: pl.DataFrame) -> pl.DataFrame:
    """S&P XAD (advertising expense) and PPEGT (gross PP&E): footnote disclosures, undimensioned. XAD prefers
    AdvertisingExpense; MarketingAndAdvertisingExpense (which can include other marketing) is the fallback."""
    x = f.filter(pl.col("kind") == "item")
    xad = (x.filter(pl.col("tag").is_in(["AdvertisingExpense", "MarketingAndAdvertisingExpense"]) & (pl.col("qtrs") == 4))
           .with_columns(pri=(pl.col("tag") != "AdvertisingExpense").cast(pl.Int8)).sort("pri")
           .unique(["adsh"], keep="first").select("cik", "ddate", "adsh", "accepted", (pl.col("value") / 1e6).alias("xad")))
    ppe = (x.filter((pl.col("tag") == "PropertyPlantAndEquipmentGross") & (pl.col("qtrs") == 0))
           .unique(["adsh"], keep="first").select("adsh", (pl.col("value") / 1e6).alias("ppegt")))
    out = xad.join(ppe, on="adsh", how="full", coalesce=True)
    keys = x.select("adsh", "cik", "ddate", "accepted").unique("adsh")
    out = out.drop("cik", "ddate", "accepted").join(keys, on="adsh")
    return out.select("cik", pl.col("ddate").alias("datadate"), "xad", "ppegt", "adsh", "accepted").sort("cik", "datadate")


def write(df: pl.DataFrame, name: str) -> None:
    tmp = OUT / f"{name}.partial"
    df.write_parquet(tmp)
    tmp.rename(OUT / f"{name}.parquet")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    f = annual(pl.read_parquet(FACTS))
    out = {"pensions": pensions(f), "segments": segments(f), "customers": customers(f), "aoci": aoci(f), "footnote_items": footnote_items(f)}
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
        print("pension rules:", dict(p.group_by("rule").len().iter_rows()))
        k = p.drop_nulls(["pplao", "pbpro", "funded_status"])
        tol = 0.01 * k["pbpro"].abs() + 0.5
        ok = ((k["pplao"] - k["pbpro"] - k["funded_status"]).abs() <= tol).sum()
        flipped = ((k["pplao"] - k["pbpro"] + k["funded_status"]).abs() <= tol).sum() - \
            ((k["pplao"] - k["pbpro"]).abs() <= tol).sum()   # a fully funded plan matches either sign
        print(f"funded status = plan assets - PBO (within 1% of PBO) in {ok:,} of {k.height:,} reports; "
              f"{flipped:,} more with the funded status's sign reversed (a filer sign error in that element)")
    c = out["customers"]
    print("customer types:", dict(c.group_by("ctype").len().iter_rows()))
    print("sin segments:", out["segments"].filter(pl.col("sics1").is_not_null() | pl.col("naicsh").is_not_null())
          ["cik"].n_unique(), "companies")


if __name__ == "__main__":
    main()
