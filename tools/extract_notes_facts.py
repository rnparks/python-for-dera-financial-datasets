"""Extract footnote facts from the SEC Financial Statement and Notes data sets.

WHY. sec_data loads the Financial Statement data sets, which carry the
primary statements only. Three Compustat files the OSAP rebuild needs
come from footnotes, each fact qualified by XBRL dimensions:

    pension     defined-benefit plan assets and obligations
                (Compustat aco_pnfnda: pplao, pbpro)
    segment     revenue by business or operating segment
                (Compustat segment file: sales by sid, snms)
    customer    facts on the major-customers axis
                (Compustat customer segment file: cnms)
    aoci        accumulated other comprehensive income components
                (Compustat RECTA, MSA: in the equity footnote, so on the
                statements for 1-2% of firm-years only)

WHAT IS EXTRACTED. From every archive under data/raw_notes/ (fetched by
tools/fetch_notes_datasets.py), every num.tsv row, without coregistrant,
that satisfies one of these, with its dimension string from dim.tsv and
its filing from sub.tsv:

    pension     tag in PENSION_TAGS (any dimensions)
    segment     tag in REVENUE_TAGS and dimensions include the
                StatementBusinessSegmentsAxis (written "BusinessSegments=" in dim.tsv)
    customer    dimensions include the MajorCustomersAxis (any tag)
    aoci        tag in AOCI_TAGS (any dimensions)

Nothing is selected or summed here: which dimension combination is a
company's pension total, or its segment list, is decided downstream
(dera_pipeline/notes_items.py) so the rule is documented in one place.

COVER PAGES. From txt.tsv (text facts), every Security12bTitle, TradingSymbol
and SecurityExchangeName (the 10-K/10-Q/20-F cover page, tagged since 2019), by
class of stock (dimension string), with its filing: written to
data/exports/notes/cover_<archive>.parquet and combined into
data/exports/notes/cover_securities.parquet (--cover). Each listed security's
title (e.g. "American Depositary Shares, each representing ...") and exchange,
as the issuer states them.

OUTPUT. data/exports/notes/facts_<archive>.parquet, one per archive
(an archive already extracted is skipped unless --force), and
data/exports/notes/notes_facts.parquet, all archives, one row per
(adsh, tag, ddate, qtrs, uom, segments), the latest archive winning.

Run from the repository root:
    uv run python tools/extract_notes_facts.py [--force]
    uv run python tools/extract_notes_facts.py --cover [--force]
"""
from __future__ import annotations

import argparse
import io
import zipfile
from pathlib import Path

import polars as pl

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / "data" / "raw_notes"
OUT = ROOT / "data" / "exports" / "notes"

PENSION_TAGS = [
    "DefinedBenefitPlanFairValueOfPlanAssets",
    "DefinedBenefitPlanBenefitObligation",
    "DefinedBenefitPlanFundedStatusOfPlan",
    "DefinedBenefitPlanAccumulatedBenefitObligation",
    "DefinedBenefitPlanPensionPlansWithAccumulatedBenefitObligationsInExcessOfPlanAssetsAccumulatedBenefitObligation",
    "DefinedBenefitPlanAmountsRecognizedInBalanceSheet",
]
REVENUE_TAGS = [
    "Revenues",
    "RevenueFromContractWithCustomerExcludingAssessedTax",
    "RevenueFromContractWithCustomerIncludingAssessedTax",
    "SalesRevenueNet",
    "SalesRevenueGoodsNet",
    "SalesRevenueServicesNet",
    "SegmentReportingInformationRevenue",
    "SegmentReportingInformationRevenueFromExternalCustomers",
    "RevenueFromExternalCustomers",
    "RevenuesNetOfInterestExpense",
]
AOCI_TAGS = [
    "AccumulatedOtherComprehensiveIncomeLossNetOfTax",
    "AccumulatedOtherComprehensiveIncomeLossForeignCurrencyTranslationAdjustmentNetOfTax",
    "AccumulatedOtherComprehensiveIncomeLossAvailableForSaleSecuritiesAdjustmentNetOfTax",
]
COVER_TAGS = ["Security12bTitle", "TradingSymbol", "SecurityExchangeName"]
SUB_COLS = ["adsh", "cik", "name", "sic", "form", "period", "fy", "fp", "filed", "accepted", "prevrpt"]


def read(z: zipfile.ZipFile, name: str, cols: list[str] | None = None) -> pl.DataFrame:
    return pl.read_csv(io.BytesIO(z.read(name)), separator="\t", quote_char=None, infer_schema_length=0,
                       truncate_ragged_lines=True, columns=cols)


def extract(path: Path) -> pl.DataFrame:
    with zipfile.ZipFile(path) as z:
        sub = read(z, "sub.tsv", SUB_COLS)
        dim = read(z, "dim.tsv", ["dimhash", "segments"]).rename({"dimhash": "dimh"})
        num = read(z, "num.tsv", ["adsh", "tag", "version", "ddate", "qtrs", "uom", "dimh", "iprx", "value", "coreg"])
    num = num.filter(pl.col("coreg").is_null() | (pl.col("coreg") == "")).join(dim, on="dimh", how="left")
    seg = pl.col("segments").fill_null("")
    kind = (pl.when(pl.col("tag").is_in(PENSION_TAGS)).then(pl.lit("pension"))
            .when(pl.col("tag").is_in(REVENUE_TAGS) & seg.str.contains("(^|;)BusinessSegments="))
            .then(pl.lit("segment"))
            .when(seg.str.contains("MajorCustomers=")).then(pl.lit("customer"))
            .when(pl.col("tag").is_in(AOCI_TAGS)).then(pl.lit("aoci")))
    out = (num.with_columns(kind=kind).filter(pl.col("kind").is_not_null())
           .join(sub, on="adsh", how="inner")
           .with_columns(cik=pl.col("cik").cast(pl.Int64), qtrs=pl.col("qtrs").cast(pl.Int32),
                         iprx=pl.col("iprx").cast(pl.Int32), value=pl.col("value").cast(pl.Float64),
                         ddate=pl.col("ddate").str.to_date("%Y%m%d"), filed=pl.col("filed").str.to_date("%Y%m%d"),
                         accepted=pl.col("accepted").str.to_datetime("%Y-%m-%d %H:%M:%S%.f", strict=False),
                         segments=seg, archive=pl.lit(path.stem))
           .drop("coreg", "dimh"))
    return out


def extract_cover(path: Path) -> pl.DataFrame:
    with zipfile.ZipFile(path) as z:
        if "txt.tsv" not in z.namelist():
            return pl.DataFrame()
        sub = read(z, "sub.tsv", SUB_COLS)
        dim = read(z, "dim.tsv", ["dimhash", "segments"]).rename({"dimhash": "dimh"})
        lf = pl.read_csv(io.BytesIO(z.read("txt.tsv")), separator="\t", quote_char=None, infer_schema_length=0,
                         truncate_ragged_lines=True, columns=["adsh", "tag", "ddate", "dimh", "coreg", "value"])
    t = lf.filter(pl.col("tag").is_in(COVER_TAGS) & (pl.col("coreg").is_null() | (pl.col("coreg") == "")))
    return (t.join(dim, on="dimh", how="left").join(sub, on="adsh", how="inner")
            .with_columns(cik=pl.col("cik").cast(pl.Int64), segments=pl.col("segments").fill_null(""),
                          accepted=pl.col("accepted").str.to_datetime("%Y-%m-%d %H:%M:%S%.f", strict=False),
                          archive=pl.lit(path.stem))
            .select("cik", "adsh", "form", "period", "accepted", "segments", "tag", "value", "archive"))


def main_cover(force: bool) -> None:
    zips = sorted(RAW.glob("*.zip"))
    for i, p in enumerate(zips, 1):
        dest = OUT / f"cover_{p.stem}.parquet"
        if dest.exists() and not force:
            continue
        df = extract_cover(p)
        tmp = dest.with_suffix(".partial")
        df.write_parquet(tmp)
        tmp.rename(dest)
        print(f"({i}/{len(zips)}) {p.name}: {df.height:,} cover facts", flush=True)
    parts = [pl.read_parquet(f) for f in sorted(OUT.glob("cover_2*.parquet"))]
    allc = pl.concat([x for x in parts if x.height], how="diagonal_relaxed").unique(
        ["adsh", "segments", "tag", "value"])
    tmp = OUT / "cover_securities.partial"
    allc.write_parquet(tmp)
    tmp.rename(OUT / "cover_securities.parquet")
    print(f"cover_securities.parquet: {allc.height:,} facts, {allc['cik'].n_unique():,} companies")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--cover", action="store_true", help="extract cover-page security titles, symbols, exchanges")
    args = ap.parse_args()
    if args.cover:
        OUT.mkdir(parents=True, exist_ok=True)
        main_cover(args.force)
        return
    OUT.mkdir(parents=True, exist_ok=True)
    zips = sorted(RAW.glob("*.zip"))
    for i, p in enumerate(zips, 1):
        dest = OUT / f"facts_{p.stem}.parquet"
        if dest.exists() and not args.force:
            continue
        df = extract(p)
        tmp = dest.with_suffix(".partial")
        df.write_parquet(tmp)
        tmp.rename(dest)
        print(f"({i}/{len(zips)}) {p.name}: {df.height:,} facts "
              f"({', '.join(f'{k} {n:,}' for k, n in df.group_by('kind').len().sort('kind').iter_rows())})", flush=True)
    parts = sorted(OUT.glob("facts_*.parquet"))
    allf = (pl.concat([pl.read_parquet(f) for f in parts], how="diagonal_relaxed")
            .sort("archive")
            .unique(["adsh", "tag", "ddate", "qtrs", "uom", "segments", "iprx"], keep="last"))
    tmp = OUT / "notes_facts.partial"
    allf.write_parquet(tmp)
    tmp.rename(OUT / "notes_facts.parquet")
    print(f"notes_facts.parquet: {allf.height:,} facts, {allf['cik'].n_unique():,} companies, "
          f"{allf['adsh'].n_unique():,} filings")


if __name__ == "__main__":
    main()
