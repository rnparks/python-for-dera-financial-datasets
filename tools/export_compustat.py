"""Export point-in-time Compustat-style annual items from sec_data.

WHY. Research code written for Compustat (the Chen-Zimmermann predictors, for
one) wants a firm-year table of items -- AT, CEQ, DLC -- with a date from which
each row was knowable. This builds it from sec_gold.fact_asof by the rules of
dera_pipeline/compustat.py, without the look-ahead a "latest" table carries.

WHAT IT WRITES. data/exports/compustat/annual.parquet (not tracked), one row per
(cik, datadate, avail):
    cik, datadate (fiscal year end), fyear, avail (the first NYSE session the
    row's facts were all actionable), sic (the company's latest), and every
    exported item from data/reference/compustat_item_map.csv.
A fiscal year gets a new row whenever a filing changes what was knowable about
it -- the original 10-K, then each later 10-K that restates it as a comparative
or a 10-K/A -- so an as-of join on avail returns exactly the vintage an
investor had. Rows that change nothing are dropped.

UNITS, as Compustat: dollar items in millions, share counts in millions,
per-share items (epspi, epspx, dvpsx_c) in dollars.

RULES. A fiscal year end is a value_date with a four-quarter duration fact in
a 10-K. Facts are 10-K and 10-Q facts in USD or shares; at each availability
date the fact vintage in force is the one with tradable_from <= date <
superseded_tradable. fyear follows Compustat: the calendar year of datadate,
less one when the fiscal year ends January to May.

Read-only against sec_data. Run from the repository root:
    uv run python tools/export_compustat.py [--refresh]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import polars as pl
import psycopg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dera_pipeline import compustat, config  # noqa: E402

OUT = config.PROJECT_ROOT / "data" / "exports" / "compustat"
PER_SHARE = {"epspi", "epspx", "dvpsx_c"}

FACTS_SQL = """
COPY (
  SELECT f.cik, f.tag, f.value_date, f.qtrs, f.uom, f.value, f.tradable_from, f.superseded_tradable,
         (f.form LIKE '10-K%%') AS is_10k
  FROM sec_gold.fact_asof f
  WHERE f.tag = ANY(%s) AND f.qtrs IN (0, 4) AND f.uom IN ('USD', 'shares')
    AND (f.form LIKE '10-K%%' OR f.form LIKE '10-Q%%')
) TO STDOUT WITH (FORMAT csv, HEADER)
"""
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


def states(facts: pl.DataFrame) -> pl.DataFrame:
    """Every (cik, datadate, avail) state: the fact vintages in force at each availability date."""
    fye = facts.filter((pl.col("qtrs") == 4) & pl.col("is_10k")).select("cik", "value_date").unique()
    f = facts.join(fye, on=["cik", "value_date"])  # instants at the year end, and four-quarter flows
    events = f.select("cik", "value_date", pl.col("tradable_from").alias("avail")).unique()
    s = f.join(events, on=["cik", "value_date"])
    s = s.filter((pl.col("tradable_from") <= pl.col("avail")) &
                 (pl.col("superseded_tradable").is_null() | (pl.col("superseded_tradable") > pl.col("avail"))))
    # one value per tag and state (a fact key can appear once per uom)
    return s.group_by("cik", "value_date", "avail", "tag").agg(pl.col("value").first())


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--refresh", action="store_true", help="re-read facts from sec_data")
    args = ap.parse_args(argv)
    items = compustat.load_map()
    problems = compustat.validate(items, compustat.load_element_docs())
    if problems:
        raise SystemExit("compustat_item_map.csv is not sound:\n  " + "\n  ".join(problems))
    tags = sorted(set().union(*(i.tags_used() for i in items.values())))

    OUT.mkdir(parents=True, exist_ok=True)
    facts_csv, sic_csv = OUT / "facts_annual.csv", OUT / "sic.csv"
    if args.refresh or not facts_csv.exists():
        print(f"reading {len(tags)} tags from sec_gold.fact_asof ...", flush=True)
        copy_out(FACTS_SQL, facts_csv, (tags,))
        copy_out(SIC_SQL, sic_csv)
    facts = pl.read_csv(facts_csv, try_parse_dates=True,
                        schema_overrides={"value": pl.Float64, "is_10k": pl.String})
    facts = facts.with_columns(is_10k=pl.col("is_10k") == "t")  # Postgres writes booleans as t/f
    print(f"{facts.height:,} facts", flush=True)

    st = states(facts)
    wide = st.pivot(on="tag", index=["cik", "value_date", "avail"], values="value").sort(["cik", "value_date", "avail"])
    print(f"{wide.height:,} firm-year states for {wide['cik'].n_unique():,} companies", flush=True)
    pdf = wide.to_pandas()
    res = compustat.resolve_frame(pdf.drop(columns=["cik", "value_date", "avail"]), items)
    out_items = compustat.exported(items)
    for c in out_items:
        if c not in PER_SHARE:
            res[c] = res[c] / 1e6
    panel = pl.from_pandas(pdf[["cik", "value_date", "avail"]].join(res[out_items])).rename({"value_date": "datadate"})
    # drop states that change nothing relative to the previous state of the same fiscal year
    changed = pl.any_horizontal([pl.col(c).ne_missing(pl.col(c).shift(1).over(["cik", "datadate"])) for c in out_items])
    panel = panel.filter(changed | (pl.col("avail") == pl.col("avail").min().over(["cik", "datadate"])))
    sic = pl.read_csv(sic_csv)
    panel = (panel.with_columns(fyear=fyear(pl.col("datadate")))
             .join(sic, on="cik", how="left")
             .select(["cik", "datadate", "fyear", "avail", "sic"] + out_items))
    panel.write_parquet(OUT / "annual.parquet")
    cov = panel.sort("avail").unique(["cik", "datadate"], keep="first")
    print(f"wrote {OUT.relative_to(config.PROJECT_ROOT)}/annual.parquet: {panel.height:,} rows, "
          f"{cov.height:,} firm-years, {panel['cik'].n_unique():,} companies")
    share = cov.select([pl.col(c).is_not_null().mean().alias(c) for c in out_items]).row(0, named=True)
    print("first-vintage coverage:", ", ".join(f"{k} {v:.0%}" for k, v in sorted(share.items(), key=lambda kv: -kv[1])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
