"""Export point-in-time Compustat-style annual items from sec_data.

WHY. Research code written for Compustat (the Chen-Zimmermann predictors, for
one) wants a firm-year table of items -- AT, CEQ, DLC -- with a date from which
each row was knowable. This builds it from sec_gold.fact_asof by the rules of
dera_pipeline/compustat.py, without the look-ahead a "latest" table carries.

WHAT IT WRITES. data/exports/compustat/annual.parquet (not tracked), one row per
(cik, datadate, avail):
    cik, datadate (fiscal year end), fyear, avail (the first NYSE session the
    row's facts were all actionable), sic (the company's latest), and every
    exported item from data/reference/compustat_item_map.csv, then the helper items
    (columns starting with "_", e.g. _tempeq) for audits.
A fiscal year gets a new row whenever a filing changes what was knowable about
it -- the original 10-K, then each later 10-K that restates it as a comparative
or a 10-K/A -- so an as-of join on avail returns exactly the vintage an
investor had. Rows that change nothing are dropped.

UNITS, as Compustat: dollar items in millions, share counts in millions,
per-share items (epspi, epspx, dvpsx_c) in dollars.

RULES. A fiscal year end is a value_date with a four-quarter duration fact in
a 10-K; where two fall in one fyear, the later is kept. Facts are 10-K and 10-Q facts in USD or shares; at each availability
date the fact vintage in force is the one with tradable_from <= date <
superseded_tradable, supersession counted among 10-K and 10-Q vintages only
(an 8-K or registration statement re-filing a number does not end it). fyear follows Compustat: the calendar year of datadate,
less one when the fiscal year ends January to May.

Read-only against sec_data. Run from the repository root:
    uv run python tools/export_compustat.py [--refresh]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import pandas as pd
import polars as pl
import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dera_pipeline import compustat, config  # noqa: E402

OUT = config.PROJECT_ROOT / "data" / "exports" / "compustat"
PER_SHARE = {"epspi", "epspx", "dvpsx_c"}

# Supersession is recomputed among 10-K and 10-Q vintages only. fact_asof's superseded_tradable counts
# every form, so an 8-K recast or an S-1/S-4 that re-files a number would end the 10-K vintage while the
# superseding row (not a 10-K/10-Q) is filtered out here, leaving nothing in force for the tag (MSFT
# FY2023 Assets after its 2024-12-04 8-K). Compustat updates from periodic reports; so does this. Nil-valued
# vintages (325,119 facts) are left out so they cannot supersede a value.
FACTS_SQL = """
COPY (
  SELECT cik, tag, value_date, qtrs, uom, value, tradable_from,
         lead(tradable_from) OVER (PARTITION BY cik, tag, value_date, qtrs, uom
                                   ORDER BY tradable_from, known_at, vintage_seq) AS superseded_tradable,
         is_10k, adsh
  FROM (SELECT f.cik, f.tag, f.value_date, f.qtrs, f.uom, f.value, f.tradable_from, f.known_at, f.vintage_seq,
               (f.form LIKE '10-K%%') AS is_10k, f.adsh
        FROM sec_gold.fact_asof f
        WHERE f.tag = ANY(%s) AND f.qtrs IN (0, 4) AND f.uom IN ('USD', 'shares') AND f.value IS NOT NULL
          AND (f.form LIKE '10-K%%' OR f.form LIKE '10-Q%%')) f
) TO STDOUT WITH (FORMAT csv, HEADER)
"""
PRES_SQL = """
COPY (SELECT p.adsh, p.report, p.line, p.stmt, p.tag, p.plabel FROM sec_silver.pre_silver p
      WHERE p.adsh = ANY(%s) AND p.stmt IN ('BS', 'IS', 'CF', 'EQ'))
TO STDOUT WITH (FORMAT csv, HEADER)
"""
NONNEG = ("capx", "dp", "xint", "xrd")
ELEMENT_DOCS = compustat.load_element_docs()
PSTK_BEFORE_ADD: list = []   # non-negative by S&P's definitions; a negative filed value is a sign slip
SIC_SQL = "COPY (SELECT DISTINCT ON (cik) cik, sic FROM sec_silver.sub_silver ORDER BY cik, filed_date DESC) TO STDOUT WITH (FORMAT csv, HEADER)"


def copy_out(sql: str, path: Path, params=None) -> None:
    """COPY a query to a CSV, renamed into place only when complete (a failed read leaves nothing)."""
    tmp = path.with_suffix(".partial")
    with psycopg.connect(config.pg_dsn()) as con, con.cursor() as cur, tmp.open("wb") as f:
        with cur.copy(sql, params) as cp:
            for chunk in cp:
                f.write(chunk)
    tmp.rename(path)


def fyear(datadate: pl.Expr) -> pl.Expr:
    return pl.when(datadate.dt.month() <= 5).then(datadate.dt.year() - 1).otherwise(datadate.dt.year())


PERIODS = pl.DataFrame(schema={"adsh": pl.String, "period": pl.Date})   # set in main(): adsh -> period end
PERIOD_SQL = "COPY (SELECT adsh, period_date AS period FROM sec_silver.sub_silver WHERE form LIKE '10-K%%') TO STDOUT WITH (FORMAT csv, HEADER)"


def states(facts: pl.DataFrame) -> pl.DataFrame:
    """Every (cik, datadate, avail) state: the fact vintages in force at each availability date."""
    fye = facts.filter((pl.col("qtrs") == 4) & pl.col("is_10k")).select("cik", "value_date").unique()
    f = facts.join(fye, on=["cik", "value_date"])  # instants at the year end, and four-quarter flows
    events = f.select("cik", "value_date", pl.col("tradable_from").alias("avail")).unique()
    s = f.join(events, on=["cik", "value_date"])
    s = s.filter((pl.col("tradable_from") <= pl.col("avail")) &
                 (pl.col("superseded_tradable").is_null() | (pl.col("superseded_tradable") > pl.col("avail"))))
    # one value per tag and state (a fact key can appear once per uom)
    # if two in-force facts for a tag differ, the most recent vintage, deterministically
    vals = (s.sort("tradable_from", "value", descending=[True, False])
            .group_by("cik", "value_date", "avail", "tag").agg(pl.col("value").first()))
    # the governing annual report of a state: the latest 10-K among its in-force facts that reports this
    # fiscal year as its own period (a later 10-K's balance sheet is about a later year end)
    own = s.filter(pl.col("is_10k")).join(PERIODS, on="adsh", how="inner").filter(pl.col("period") == pl.col("value_date"))
    gov = (own.sort("tradable_from", descending=True)
           .group_by("cik", "value_date", "avail").agg(pl.col("adsh").first().alias("gov_adsh")))
    return vals, gov


def refused_facts(facts: pl.DataFrame, pres: pl.DataFrame, rules: list[dict]) -> pl.DataFrame:
    """Drop the facts a refuse_tag rule rejects: the tag, from a filing that presents it with the rule's label.
    (The rule's component tags are used by compustat.revenues_include_nonoperating on the filed values; their
    position on the statement is not used: generic tags such as OtherIncome also carry operating revenue,
    e.g. Walmart's membership income.)"""
    for r in [r for r in rules if r["rule"] == "refuse_tag"]:
        bad = (pres.filter(pl.col("stmt").is_in(sorted(r["statements"])) & (pl.col("tag") == r["tag"])
                           & pl.col("plabel").fill_null("").str.contains("(?i)" + r["label"].pattern))
               .select("adsh").unique())
        n0 = facts.height
        facts = facts.join(bad.with_columns(_bad=pl.lit(True)), on="adsh", how="left").filter(
            ~((pl.col("tag") == r["tag"]) & pl.col("_bad").fill_null(False))).drop("_bad")
        print(f"presentation rule: {n0 - facts.height:,} {r['tag']} facts refused for {r['item']} ({bad.height:,} filings)")
    return facts


def presentation_sets(pres: pl.DataFrame, rules: list[dict], items) -> dict[tuple[str, str], set[str]]:
    """(item, rule) -> the filings (adsh) where a zero or add_if_label rule applies."""
    out = {}
    for r in rules:
        on = pres.filter(pl.col("stmt").is_in(sorted(r["statements"])))
        lab = pl.col("plabel").fill_null("").str.contains("(?i)" + r["label"].pattern)
        if r.get("exclude") is not None:
            lab = lab & ~pl.col("plabel").fill_null("").str.contains("(?i)" + r["exclude"].pattern)
        if r["rule"] == "zero":
            fam = sorted(compustat.family_tags(items, r["item"], ELEMENT_DOCS) | r["family"])
            hit = on.filter(pl.col("tag").is_in(fam) | lab).select("adsh").unique()
            ok = on.select("adsh").unique().join(hit, on="adsh", how="anti")
            out[(r["item"], "zero")] = set(ok["adsh"].to_list())
        elif r["rule"] == "add_if_label":
            out[(r["item"], "add_if_label")] = set(on.filter((pl.col("tag") == r["tag"]) & lab)["adsh"].to_list())
        # zero_if_zero needs no presentation: it follows another item's resolved value
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--refresh", action="store_true", help="re-read facts from sec_data")
    args = ap.parse_args(argv)
    items = compustat.load_map()
    problems = compustat.validate(items, compustat.load_element_docs())
    if problems:
        raise SystemExit("compustat_item_map.csv is not sound:\n  " + "\n  ".join(problems))
    tags = sorted(set().union(*(i.tags_used() for i in items.values()),
                              *(r["components"] for r in compustat.load_presentation_rules())))

    OUT.mkdir(parents=True, exist_ok=True)
    facts_csv, sic_csv, tags_txt = OUT / "facts_annual.csv", OUT / "sic.csv", OUT / "facts_annual.tags"
    # the cached facts are only valid for the tag list they were read with
    stale = not tags_txt.exists() or tags_txt.read_text().split() != tags
    if args.refresh or not facts_csv.exists() or stale:
        print(f"reading {len(tags)} tags from sec_gold.fact_asof ...", flush=True)
        copy_out(FACTS_SQL, facts_csv, (tags,))
        copy_out(SIC_SQL, sic_csv)
        tags_txt.write_text("\n".join(tags))
    facts = pl.read_csv(facts_csv, try_parse_dates=True,
                        schema_overrides={"value": pl.Float64, "is_10k": pl.String})
    facts = facts.with_columns(is_10k=pl.col("is_10k") == "t")  # Postgres writes booleans as t/f
    print(f"{facts.height:,} facts", flush=True)
    rules = compustat.load_presentation_rules()
    pres_csv = OUT / "presentation_annual.csv"
    if args.refresh or not pres_csv.exists() or stale:
        print("reading face-statement presentation of the filings ...", flush=True)
        copy_out(PRES_SQL, pres_csv, (sorted(facts["adsh"].unique().to_list()),))
    pres = pl.read_csv(pres_csv, schema_overrides={"plabel": pl.String, "tag": pl.String})
    facts = refused_facts(facts, pres, rules)

    global PERIODS
    per_csv = OUT / "periods_10k.csv"
    if args.refresh or not per_csv.exists():
        copy_out(PERIOD_SQL, per_csv)
    PERIODS = pl.read_csv(per_csv, try_parse_dates=True).with_columns(pl.col("period").cast(pl.Date))
    st, gov = states(facts)
    wide = st.pivot(on="tag", index=["cik", "value_date", "avail"], values="value").sort(["cik", "value_date", "avail"])
    print(f"{wide.height:,} firm-year states for {wide['cik'].n_unique():,} companies", flush=True)
    pdf = wide.to_pandas()
    comps = set().union(*(r["components"] for r in rules if r["rule"] == "refuse_tag"))
    inc = compustat.revenues_include_nonoperating(pdf, comps)
    pdf.loc[inc, "Revenues"] = float("nan")
    print(f"presentation rule: Revenues refused in {int(inc.sum()):,} states where it equals sales plus non-operating income")
    res = compustat.resolve_frame(pdf.drop(columns=["cik", "value_date", "avail"]), items)
    out_items = compustat.exported(items)
    helpers = sorted(n for n in items if n.startswith("_"))
    for c in out_items + helpers:
        if c not in PER_SHARE:
            res[c] = res[c] / 1e6
    for c in NONNEG:
        res[c] = res[c].abs()
    # COGS from the bank variant (interest expense + loan-loss provision) only for financial SICs: captive-finance
    # industrials (Deere) file a provision too. COGS from S&P's identity (SALE - XSGA - DP - OIADP) only where
    # it is between 0 and 1.2 x sales (negative when XSGA already carries D&A).
    sic = pdf[["cik"]].merge(pl.read_csv(sic_csv).to_pandas(), on="cik", how="left").sic.values
    fin = (sic >= 6000) & (sic < 7000)
    bank = (pdf.get("InterestExpense") + pdf.get("ProvisionForLoanLeaseAndOtherLosses")) / 1e6 \
        if "ProvisionForLoanLeaseAndOtherLosses" in pdf and "InterestExpense" in pdf else None
    if bank is not None:
        took_bank = (res["cogs"] - bank.values).abs() < 1e-6
        res.loc[took_bank.values & ~fin, "cogs"] = float("nan")
    ident = res["sale"] - res["xsga"] - res["dp"] - res["oiadp"]
    took_ident = (res["cogs"] - ident).abs() < 1e-6
    implaus = took_ident & ~((res["cogs"] >= 0) & (res["cogs"] <= 1.2 * res["sale"]))
    res.loc[implaus, "cogs"] = float("nan")
    # presentation rules, on each state's governing 10-K
    g = pdf[["cik", "value_date", "avail"]].merge(gov.to_pandas(), on=["cik", "value_date", "avail"], how="left").gov_adsh
    g.index = res.index
    sets = presentation_sets(pres, rules, items)
    zeroed = pd.Series("", index=res.index)
    for r in rules:
        hit = g.isin(sets.get((r["item"], r["rule"]), set()))
        if r["rule"] == "add_if_label":
            amt = (pdf[r["tag"]] / 1e6).where(hit.values, 0.0).fillna(0.0) if r["tag"] in pdf else 0.0
            amt = pd.Series(amt, index=res.index) if not isinstance(amt, pd.Series) else amt.set_axis(res.index)
            # only where no preferred is resolved from permanent equity: a filer that tags PreferredStockValue for
            # the same redeemable instrument would otherwise be counted twice (IEA FY2019)
            if r["item"] == "pstk":
                PSTK_BEFORE_ADD[:] = [res["pstk"].copy()]
            base = PSTK_BEFORE_ADD[0] if PSTK_BEFORE_ADD else res["pstk"]
            amt = amt.where(base.fillna(0) == 0, 0.0)
            if r["item"] == "pstk":
                res["pstk"] = res["pstk"].where(amt == 0, res["pstk"].fillna(0) + amt)
                res["pstkl"] = res["pstkl"].where(amt == 0, res["pstkl"].fillna(0) + amt)
            else:
                res[r["item"]] = res[r["item"]] + amt
        elif r["rule"] == "zero":
            z = hit & res[r["item"]].isna()
            res.loc[z, r["item"]] = 0.0
            zeroed[z] = zeroed[z] + r["item"] + " "
        elif r["rule"] == "zero_if_zero":       # 'tag' names the item this one follows
            z = (res[r["tag"]] == 0) & res[r["item"]].isna()
            res.loc[z, r["item"]] = 0.0
            zeroed[z] = zeroed[z] + r["item"] + " "
            hit = z
        if r["rule"] != "refuse_tag":
            print(f"presentation rule {r['rule']} {r['item']}: {int(hit.sum()):,} states eligible", flush=True)
    res["zeroed_items"] = zeroed.str.strip()
    panel = pl.from_pandas(pdf[["cik", "value_date", "avail"]].join(res[out_items + helpers + ["zeroed_items"]])).rename({"value_date": "datadate"})
    # drop states that change nothing relative to the previous state of the same fiscal year
    changed = pl.any_horizontal([pl.col(c).ne_missing(pl.col(c).shift(1).over(["cik", "datadate"])) for c in out_items])
    panel = panel.filter(changed | (pl.col("avail") == pl.col("avail").min().over(["cik", "datadate"])))
    sic = pl.read_csv(sic_csv)
    panel = (panel.with_columns(fyear=fyear(pl.col("datadate")))
             .join(sic, on="cik", how="left")
             .select(["cik", "datadate", "fyear", "avail", "sic"] + out_items + helpers + ["zeroed_items"]))
    # one fiscal year end per fyear, as Compustat: a fiscal-year change or a reverse merger that keeps the
    # shell's year end can leave two datadates in one fyear; the later one is the fiscal year
    last = panel.group_by("cik", "fyear").agg(pl.col("datadate").max().alias("keep"))
    n0 = panel.select("cik", "datadate").unique().height
    panel = panel.join(last, on=["cik", "fyear"]).filter(pl.col("datadate") == pl.col("keep")).drop("keep")
    print(f"dropped {n0 - panel.select('cik', 'datadate').unique().height:,} superseded fiscal year ends sharing an fyear")
    panel.write_parquet(OUT / "annual.parquet")
    cov = panel.sort("avail").unique(["cik", "datadate"], keep="first")
    print(f"wrote {OUT.relative_to(config.PROJECT_ROOT)}/annual.parquet: {panel.height:,} rows, "
          f"{cov.height:,} firm-years, {panel['cik'].n_unique():,} companies")
    share = cov.select([pl.col(c).is_not_null().mean().alias(c) for c in out_items]).row(0, named=True)
    print("first-vintage coverage:", ", ".join(f"{k} {v:.0%}" for k, v in sorted(share.items(), key=lambda kv: -kv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
