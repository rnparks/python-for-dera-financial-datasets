"""Three ways to score a factor, sector-neutral, equal- and cap-weighted, side by side.

The same nine accounting factors and the same composite, scored three ways
within each (date, GICS sector) group of a universe's factor panel:

  aqr    z-score of the RANK (Asness, Frazzini and Pedersen 2019, "Quality
         Minus Junk": ranks, standardised, averaged, re-standardised)
  msci   the raw value winsorised at the 5th and 95th percentile of the
         group, then z-scored (MSCI Quality Indexes Methodology, May 2022)
  barra  the raw value winsorised at the group mean +/- 3 standard
         deviations, then z-scored (MSCI FaCS / Barra; here with an
         equal-weighted mean and a single winsorisation pass)

The composite is the mean of a member's available factor scores (four or
more), re-standardised within the group. The sort is the strict sector-
neutral one: within each sector on each rebalance date, quintiles by
score; the sector's spread is its top fifth minus its bottom fifth; the
universe spread averages the sector spreads. Three weightings:

  cw     equal weight per stock within a leg, sectors weighted by member
         count: an equal-weighted long book against an equal-weighted
         short book with the sector mix matched (the headline)
  ew     equal weight per stock, every sector weighted the same
  vw     market-cap weight per stock within each sector's leg, sectors
         weighted by their share of the universe's market cap on the
         rebalance date, the same weights on both sides

Market cap is sec_market.market_cap_at (the month-end close before the
date times the cover-page shares knowable on it), computed once per
company-date of the panel and cached in <ff-dir>/market_cap_panel.csv
(gitignored; the cache is extended for new company-dates on each run).
A member without a market cap drops out of the cap-weighted legs only,
and so does a company-date whose cap exceeds MAX_CAP_SHARE of the
panel's total that date: no real member holds more than about 8%, and
what exceeds it is a share count the ladder's scale guards could not
refuse (a filer whose nearby filings all carry the same error) or a
split between the price's month end and the cover page; the page lists
every such company-date.
Sectors with fewer than ten scored members on a date are left out.
Holding and return matching are exactly those of sec_market.backtest
(held to the next rebalance, the ticker the spine assigns on the
rebalance date).

Every spread is measured raw and against FF5 and FF5 + UMD with
Newey-West (six lags) t-statistics, with the code of tools/ff_baseline.py.
Nothing is written to the database.

With --variants the same sorts are run three ways and compared on one page:

  sector         scoring within the sector, as above (the shipped numbers)
  industry       a Financials member's measures standardised within its
                 industry group by SIC code (sec_reference.company.sic_latest:
                 banks 6000-6099, insurance 6300-6499, REITs 6798, financial
                 services otherwise), the sort still within the sector; a
                 group under ten members on a date, or a member without a
                 SIC, is scored within the sector
  ex-financials  the academic control: Financials and Real Estate (the two
                 GICS sectors of SIC 6000-6999) dropped before scoring

The page also measures where each industry group's members land in the
sector's quintiles under the first two.

Usage:
  uv run python tools/score_methods.py                 # all four universes
  uv run python tools/score_methods.py --universes SP500,SP1500
  uv run python tools/score_methods.py --variants      # plus the two other variants and the comparison page
Writes <ff-dir>/score_methods_<universe>.csv (every statistic, every
weighting), <ff-dir>/score_methods_series_<universe>.csv (the monthly
legs and spreads) and docs/reports/score_methods_sector_neutral_<date>.html;
with --variants also <ff-dir>/score_methods_<universe>_<variant>.csv and the
series file for the two other variants, and
docs/reports/score_methods_financials_<date>.html.
"""
from __future__ import annotations

import argparse
import datetime as dt
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from factor_report import CSS, LABEL, esc, num, pct, tcell  # noqa: E402
from ff_baseline import MODELS, annualise, load_french, newey_west_ols  # noqa: E402

from dera_pipeline import config, db  # noqa: E402

UNIVERSES = ["SP500", "SP400", "SP600", "SP1500"]
METHODS = {
    "aqr": ("AQR", "z-score of the rank"),
    "msci": ("MSCI", "raw value winsorised at the 5th/95th percentile, z-scored"),
    "barra": ("Barra", "raw value winsorised at mean ± 3 sd, z-scored"),
}
WEIGHTINGS = {
    "cw": "equal-weighted stocks, sectors by member count",
    "ew": "equal-weighted stocks, sectors equal",
    "vw": "cap-weighted stocks, sectors by market cap",
}
FACTORS = [
    ("composite", "Composite"), ("gp_at", "Gross profit / assets"), ("ocf_at", "Operating cash flow / assets"),
    ("roa", "Return on assets"), ("roe", "Return on equity"), ("operating_margin", "Operating margin"),
    ("revenue_growth", "Revenue growth (low is good)"), ("roe_q", "Quarterly ROE"), ("roa_q", "Quarterly ROA"),
    ("sue", "Earnings surprise (SUE)"),
]
FREQS = ["monthly", "quarterly", "annual"]
MIN_SECTOR = 10
# A descriptive cut, not a fitted one: the month from which the Fama-French
# profitability factor (RMW) reversed, which the report's legs table splits on.
SPLIT_YM = "202501"
CAP_WORKERS = 6
# A cap above this share of the panel's total on its date is a defect, not
# a cap (the real maximum, Apple or Nvidia, is about 8%), and is left out.
MAX_CAP_SHARE = 0.15
# Industry groups inside one sector, by the filer's SIC code (the
# classification the SEC assigns, sec_reference.company.sic_latest), for the
# industry-relative variant: a member's measures are standardised within its
# group, the sort stays within the sector. Any other SIC is INDUSTRY_OTHER.
INDUSTRY_SECTOR = "Financials"
INDUSTRY_GROUPS = (("banks", 6000, 6099), ("insurance", 6300, 6499), ("REITs", 6798, 6798))
INDUSTRY_OTHER = "financial services"
MIN_GROUP = MIN_SECTOR
# variant -> (label, grouping, sectors excluded before scoring)
VARIANTS = {
    "sector": ("sector-relative", "sector", ()),
    "industry": ("industry-relative", "industry", ()),
    "ex-financials": ("ex-Financials and Real Estate", "sector", ("Financials", "Real Estate")),
}


def industry_group(sic: int | None) -> str | None:
    """The industry group a SIC code puts a member of INDUSTRY_SECTOR in (pure); None without a SIC."""
    if sic is None:
        return None
    for name, lo, hi in INDUSTRY_GROUPS:
        if lo <= sic <= hi:
            return name
    return INDUSTRY_OTHER


def industry_group_sql(column: str = "c.sic_latest") -> str:
    """The same rule as a SQL CASE over `column` (pure)."""
    whens = " ".join(f"WHEN {column} BETWEEN {lo} AND {hi} THEN '{name}'" for name, lo, hi in INDUSTRY_GROUPS)
    return f"CASE WHEN {column} IS NULL THEN NULL {whens} ELSE '{INDUSTRY_OTHER}' END"


# The scoring: every measure standardised within its scoring group (sgrp),
# the sector or, for the industry-relative variant, the industry group
# inside INDUSTRY_SECTOR; the composite re-standardised within the sector,
# which leaves the within-sector order unchanged; the sort within the sector.
SQL_SCORE = """
WITH p0 AS (
  SELECT fp.asof, fp.cik, fp.gics_sector, fp.gp_at, fp.ocf_at, fp.roa, fp.roe, fp.operating_margin,
         -fp.revenue_growth AS revenue_growth, fp.roe_q, fp.roa_q, fp.sue,
         CASE WHEN %(grouping)s = 'industry' AND fp.gics_sector = %(industry_sector)s
              THEN fp.gics_sector || ' / ' || __SIC_CASE__ END AS igrp
  FROM sec_market.factor_panel fp LEFT JOIN sec_reference.company c ON c.cik = fp.cik
  WHERE fp.index_name = %(u)s AND fp.gics_sector IS NOT NULL AND NOT (fp.gics_sector = ANY (%(exclude)s::text[]))),
p AS (
  SELECT p0.*, CASE WHEN igrp IS NOT NULL AND count(*) OVER (PARTITION BY asof, igrp) >= %(min_group)s THEN igrp END AS igrp_ok
  FROM p0),
-- Every member's values enter its sector's group, so a member whose industry
-- group is too small is scored against the whole sector; a member with a
-- qualifying industry group enters that too, and that row is its own score.
long AS (
  SELECT p.asof, p.cik, p.gics_sector, g.sgrp, g.own, f.factor, f.val
  FROM p,
       LATERAL (VALUES (p.gics_sector, p.igrp_ok IS NULL), (p.igrp_ok, TRUE)) AS g(sgrp, own),
       LATERAL (VALUES ('gp_at', p.gp_at), ('ocf_at', p.ocf_at), ('roa', p.roa), ('roe', p.roe),
                ('operating_margin', p.operating_margin), ('revenue_growth', p.revenue_growth),
                ('roe_q', p.roe_q), ('roa_q', p.roa_q), ('sue', p.sue)) AS f(factor, val)
  WHERE g.sgrp IS NOT NULL AND f.val IS NOT NULL),
grp AS (
  SELECT asof, sgrp, factor,
         percentile_cont(0.05) WITHIN GROUP (ORDER BY val) AS p5, percentile_cont(0.95) WITHIN GROUP (ORDER BY val) AS p95,
         avg(val) AS mu, stddev_samp(val) AS sd
  FROM long GROUP BY 1, 2, 3),
ranked AS (SELECT l.*, rank() OVER (PARTITION BY asof, sgrp, factor ORDER BY val) AS rk FROM long l),
x AS (
  SELECT r.asof, r.cik, r.gics_sector, r.sgrp, r.own, r.factor,
         CASE %(m)s WHEN 'aqr'   THEN r.rk::numeric
                   WHEN 'msci'  THEN LEAST(g.p95, GREATEST(g.p5, r.val))
                   WHEN 'barra' THEN LEAST(g.mu + 3 * g.sd, GREATEST(g.mu - 3 * g.sd, r.val)) END AS v
  FROM ranked r JOIN grp g USING (asof, sgrp, factor)),
z AS (
  SELECT asof, cik, gics_sector, own, factor, (v - avg(v) OVER w) / NULLIF(stddev_samp(v) OVER w, 0) AS z
  FROM x WINDOW w AS (PARTITION BY asof, sgrp, factor)),
comp AS (SELECT asof, cik, gics_sector, avg(z) AS z FROM z WHERE own AND z IS NOT NULL GROUP BY 1, 2, 3 HAVING count(z) >= 4),
sig AS (
  SELECT asof, cik, gics_sector, factor, z AS signal FROM z WHERE own
  UNION ALL
  SELECT asof, cik, gics_sector, 'composite', (z - avg(z) OVER w) / NULLIF(stddev_samp(z) OVER w, 0)
  FROM comp WINDOW w AS (PARTITION BY asof, gics_sector)),
""".replace("__SIC_CASE__", industry_group_sql())

SQL_SORT = """
fr AS (SELECT * FROM (VALUES ('monthly'), ('quarterly'), ('annual')) v(freq)),
first_month AS (SELECT EXTRACT(MONTH FROM min(asof)) AS m FROM p),
dates AS (
  SELECT fr.freq, d.asof FROM fr, (SELECT DISTINCT asof FROM p) d, first_month
  WHERE fr.freq = 'monthly' OR (fr.freq = 'quarterly' AND EXTRACT(MONTH FROM d.asof) IN (3, 6, 9, 12))
     OR (fr.freq = 'annual' AND EXTRACT(MONTH FROM d.asof) = first_month.m)),
windows AS (SELECT freq, asof AS rebalance_date, LEAD(asof) OVER (PARTITION BY freq ORDER BY asof) AS next_rebalance FROM dates),
members AS (
  SELECT w.freq, s.factor, w.rebalance_date, w.next_rebalance, s.cik, s.gics_sector, s.signal,
         sec_reference.ticker_at(s.cik, w.rebalance_date) AS ticker_then, c.market_cap,
         count(*) OVER (PARTITION BY w.freq, s.factor, w.rebalance_date, s.gics_sector) AS sector_n
  FROM windows w JOIN sig s ON s.asof = w.rebalance_date
  LEFT JOIN cap c ON c.asof = w.rebalance_date AND c.cik = s.cik
  WHERE s.signal IS NOT NULL),
sorted AS (
  SELECT m.*, NTILE(5) OVER (PARTITION BY m.freq, m.factor, m.rebalance_date, m.gics_sector ORDER BY m.signal, m.cik) AS bucket,
         sum(m.market_cap) OVER (PARTITION BY m.freq, m.factor, m.rebalance_date, m.gics_sector)
           / NULLIF(sum(m.market_cap) OVER (PARTITION BY m.freq, m.factor, m.rebalance_date), 0) AS sector_w
  FROM members m WHERE m.sector_n >= %(min_sector)s),
held AS (
  SELECT s.freq, s.factor, s.gics_sector, s.bucket, s.market_cap, s.sector_w, r.month_end, r.ret_1m
  FROM sorted s JOIN sec_market.monthly_return r
    ON r.cik = s.cik AND r.month_end > s.rebalance_date AND r.month_end <= COALESCE(s.next_rebalance, s.rebalance_date + 400)
   AND r.ticker = COALESCE(s.ticker_then, r.ticker)
  WHERE s.bucket IN (1, 5) AND r.ret_1m IS NOT NULL),
sector_month AS (
  SELECT freq, factor, month_end, gics_sector,
         avg(ret_1m) FILTER (WHERE bucket = 5) AS ew5, avg(ret_1m) FILTER (WHERE bucket = 1) AS ew1, count(*) AS n_names,
         sum(ret_1m * market_cap) FILTER (WHERE bucket = 5) / NULLIF(sum(market_cap) FILTER (WHERE bucket = 5), 0) AS vw5,
         sum(ret_1m * market_cap) FILTER (WHERE bucket = 1) / NULLIF(sum(market_cap) FILTER (WHERE bucket = 1), 0) AS vw1,
         max(sector_w) AS sector_w
  FROM held GROUP BY 1, 2, 3, 4)
SELECT freq, factor, month_end,
       sum((ew5 - ew1) * n_names) / sum(n_names) AS spread_cw,
       sum(ew5 * n_names) / sum(n_names) AS long_cw, sum(ew1 * n_names) / sum(n_names) AS short_cw,
       avg(ew5 - ew1) AS spread_ew,
       sum((vw5 - vw1) * sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL)
         / NULLIF(sum(sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL), 0) AS spread_vw,
       sum(vw5 * sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL)
         / NULLIF(sum(sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL), 0) AS long_vw,
       sum(vw1 * sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL)
         / NULLIF(sum(sector_w) FILTER (WHERE vw5 IS NOT NULL AND vw1 IS NOT NULL), 0) AS short_vw,
       count(*) AS n_sectors
FROM sector_month WHERE ew5 IS NOT NULL AND ew1 IS NOT NULL GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
"""
SQL = SQL_SCORE + SQL_SORT

# Where each industry group's members land in INDUSTRY_SECTOR's composite
# quintiles under a scoring: the share of its company-months in the bottom
# and the top fifth, every date, the sector's quintiles as the sort uses them.
SQL_SHARES = SQL_SCORE + """
q AS (
  SELECT s.asof, s.cik, s.gics_sector, NTILE(5) OVER (PARTITION BY s.asof, s.gics_sector ORDER BY s.signal, s.cik) AS bucket,
         count(*) OVER (PARTITION BY s.asof, s.gics_sector) AS sector_n
  FROM sig s WHERE s.factor = 'composite' AND s.signal IS NOT NULL)
SELECT COALESCE(__SIC_CASE__, 'no SIC') AS grp, count(*) AS company_months,
       100.0 * avg((q.bucket = 1)::int) AS pct_bottom, 100.0 * avg((q.bucket = 5)::int) AS pct_top
FROM q LEFT JOIN sec_reference.company c ON c.cik = q.cik
WHERE q.gics_sector = %(industry_sector)s AND q.sector_n >= %(min_sector)s
GROUP BY 1 ORDER BY 2 DESC
""".replace("__SIC_CASE__", industry_group_sql())

SQL_CAP = """
SELECT d.asof, d.cik, m.market_cap
FROM unnest(%(asof)s::date[], %(cik)s::int[]) AS d(asof, cik)
LEFT JOIN LATERAL sec_market.market_cap_at(d.cik, d.asof) m ON TRUE
"""

# The survivorship caveat, measured: the share of a universe's scored members
# with a return the following month, by composite quintile (index-wide
# percentile composite, the one the panel stores).
SQL_PRICED = """
WITH p AS (SELECT fp.asof, fp.cik, NTILE(5) OVER (PARTITION BY fp.asof ORDER BY fp.composite, fp.cik) AS bucket,
                  sec_reference.ticker_at(fp.cik, fp.asof) AS ticker_then
           FROM sec_market.factor_panel fp WHERE fp.index_name = %(u)s AND fp.composite IS NOT NULL),
nxt AS (SELECT p.bucket,
               EXISTS (SELECT 1 FROM sec_market.monthly_return r WHERE r.cik = p.cik AND r.ret_1m IS NOT NULL
                       AND r.month_end > p.asof AND r.month_end <= p.asof + 35
                       AND r.ticker = COALESCE(p.ticker_then, r.ticker)) AS priced
        FROM p WHERE p.asof < (SELECT max(month_end) FROM sec_market.monthly_return))
SELECT bucket, round(100.0 * avg(priced::int), 1) FROM nxt GROUP BY bucket ORDER BY bucket
"""


# ------------------------------------------------------------ market cap cache

def _cap_chunk(keys: pd.DataFrame) -> pd.DataFrame:
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(SQL_CAP, {"asof": list(keys["asof"]), "cik": [int(c) for c in keys["cik"]]})
        rows = cur.fetchall()
    out = pd.DataFrame(rows, columns=["asof", "cik", "market_cap"])
    out["market_cap"] = out["market_cap"].astype(float)
    return out


def drop_dominant_caps(cap: pd.DataFrame, max_share: float = MAX_CAP_SHARE) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Null the market cap of every company-date holding more than max_share
    of that date's total across the cache (pure). Returns the frame and the
    rows dropped, with their share."""
    out = cap.copy()
    total = out.groupby("asof")["market_cap"].transform("sum")
    share = out["market_cap"] / total
    hit = share > max_share
    dropped = out[hit].assign(share=share[hit]).sort_values(["asof", "cik"]).reset_index(drop=True)
    out.loc[hit, "market_cap"] = np.nan
    return out, dropped


def ensure_cap_cache(path: Path) -> pd.DataFrame:
    """Market cap for every (date, company) of the panel, computed once and
    kept on disk; only company-dates missing from the file are computed."""
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT DISTINCT asof, cik FROM sec_market.factor_panel ORDER BY 1, 2")
        keys = pd.DataFrame(cur.fetchall(), columns=["asof", "cik"])
    if path.exists():
        cache = pd.read_csv(path, parse_dates=["asof"])
        cache["asof"] = cache["asof"].dt.date
    else:
        cache = pd.DataFrame(columns=["asof", "cik", "market_cap"])
    have = set(zip(cache["asof"], cache["cik"].astype(int))) if len(cache) else set()
    missing = keys[[(a, int(c)) not in have for a, c in zip(keys["asof"], keys["cik"])]]
    if len(missing):
        print(f"market cap: {len(missing):,} company-dates to compute ({len(have):,} cached)")
        chunks = [missing.iloc[i::CAP_WORKERS] for i in range(CAP_WORKERS)]
        with ThreadPoolExecutor(max_workers=CAP_WORKERS) as ex:
            parts = list(ex.map(_cap_chunk, [c for c in chunks if len(c)]))
        cache = pd.concat([cache] + parts, ignore_index=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        cache.to_csv(path, index=False)
        print(f"market cap: {int(cache['market_cap'].notna().sum()):,} of {len(cache):,} company-dates have one; cached at {path}")
    cache["cik"] = cache["cik"].astype(int)
    return cache


# ----------------------------------------------------------------- the sorts

def sql_params(u: str, variant: str) -> dict:
    _, grouping, exclude = VARIANTS[variant]
    return {"u": u, "min_sector": MIN_SECTOR, "min_group": MIN_GROUP, "grouping": grouping,
            "exclude": list(exclude), "industry_sector": INDUSTRY_SECTOR}


def run_universe(u: str, cap: pd.DataFrame, variant: str = "sector") -> dict[str, pd.DataFrame]:
    out = {}
    with db.get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("CREATE TEMP TABLE cap (asof DATE, cik INTEGER, market_cap NUMERIC, PRIMARY KEY (asof, cik))")
            with cur.copy("COPY cap (asof, cik, market_cap) FROM STDIN") as copy:
                for a, c, m in cap[cap["market_cap"].notna()].itertuples(index=False):
                    copy.write_row((a, int(c), float(m)))
            cur.execute("ANALYZE cap")
        for m in METHODS:
            with conn.cursor() as cur:
                cur.execute(SQL, {**sql_params(u, variant), "m": m})
                rows = cur.fetchall()
            df = pd.DataFrame(rows, columns=["freq", "factor", "month_end", "spread_cw", "long_cw", "short_cw",
                                             "spread_ew", "spread_vw", "long_vw", "short_vw", "n_sectors"])
            for c in df.columns[3:10]:
                df[c] = df[c].astype(float)
            df["ym"] = pd.to_datetime(df["month_end"]).dt.strftime("%Y%m")
            out[m] = df
    return out


def group_shares(u: str, variant: str) -> list[dict]:
    """Where INDUSTRY_SECTOR's industry groups land in its composite quintiles under a variant, AQR scoring."""
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(SQL_SHARES, {**sql_params(u, variant), "m": "aqr"})
        return [{"group": g, "company_months": int(n), "pct_bottom": float(b), "pct_top": float(t)} for g, n, b, t in cur.fetchall()]


def priced_by_quintile(u: str) -> dict[int, float]:
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(SQL_PRICED, {"u": u})
        return {int(b): float(p) for b, p in cur.fetchall()}


# ------------------------------------------------------------- the statistics

def regress(series: pd.Series, ff: pd.DataFrame) -> dict | None:
    """Raw mean and t, then alpha, t and loadings on each model; None under 24 months."""
    j = pd.DataFrame({"r": series.dropna()}).join(ff, how="inner")
    if len(j) < 24:
        return None
    y = j["r"].to_numpy(float)
    rec = {"months": len(j), "raw_ann": annualise(y.mean()),
           "raw_t": y.mean() / y.std(ddof=1) * np.sqrt(len(y))}
    for model, cols in MODELS.items():
        X = np.column_stack([np.ones(len(j))] + [j[c].to_numpy(float) for c in cols])
        beta, t, r2, _ = newey_west_ols(y, X)
        rec[f"{model} alpha_ann"] = annualise(beta[0])
        rec[f"{model} t_alpha"] = t[0]
        rec[f"{model} r2"] = r2
        for c, b in zip(cols, beta[1:]):
            rec[f"{model} b_{c}"] = b
    return rec


def summarise_counts(rows: list[dict]) -> dict:
    """Counts over a list of result rows (pure): how many clear |t| 2 raw and
    on FF5+UMD, how many spreads are positive, the mean alpha t."""
    n = len(rows)
    if n == 0:
        return {"n": 0, "sig_raw": 0, "sig_alpha": 0, "sig_alpha_pos": 0, "positive": 0, "mean_alpha_t": float("nan")}
    sig_raw = sum(1 for r in rows if abs(r["raw_t"]) >= 2)
    sig_alpha = sum(1 for r in rows if abs(r["FF5+UMD t_alpha"]) >= 2)
    sig_alpha_pos = sum(1 for r in rows if r["FF5+UMD t_alpha"] >= 2)
    positive = sum(1 for r in rows if r["raw_ann"] > 0)
    return {"n": n, "sig_raw": sig_raw, "sig_alpha": sig_alpha, "sig_alpha_pos": sig_alpha_pos,
            "positive": positive, "mean_alpha_t": sum(r["FF5+UMD t_alpha"] for r in rows) / n}


def legs_by_period(df: pd.DataFrame, split_ym: str = SPLIT_YM) -> dict[str, dict[str, float]]:
    """Annualised mean of each leg and spread, equal- and cap-weighted,
    before and from split_ym (pure): the composite's monthly rows of one
    method, as run_universe returns them."""
    g = df[(df.factor == "composite") & (df.freq == "monthly")]
    out = {}
    for label, part in (("before", g[g.ym < split_ym]), ("from", g[g.ym >= split_ym])):
        out[label] = {"months": int(len(part))}
        for c in ("long_cw", "short_cw", "spread_cw", "long_vw", "short_vw", "spread_vw"):
            out[label][c] = annualise(float(part[c].mean())) if len(part) and part[c].notna().any() else float("nan")
    return out


def agreement(frames: dict[str, pd.DataFrame], column: str, factor: str = "composite") -> dict[tuple[str, str], float]:
    """Mean correlation of the monthly spread series between each pair of
    methods over one factor's schedules in one universe. The composite is
    the only sort where the methods can differ: for a single factor the
    three scores are monotone transforms of one another within a group, so
    its quintiles are the same set under all three."""
    out = {}
    ms = list(frames)
    for i, a in enumerate(ms):
        for b in ms[i + 1:]:
            cs = []
            for (freq, f), ga in frames[a][frames[a].factor == factor].groupby(["freq", "factor"]):
                gb = frames[b][(frames[b].freq == freq) & (frames[b].factor == f)]
                j = ga.set_index("ym")[column].to_frame("a").join(gb.set_index("ym")[column].to_frame("b"), how="inner")
                if len(j) >= 24 and j["a"].std() > 0 and j["b"].std() > 0:
                    cs.append(float(j["a"].corr(j["b"])))
            out[(a, b)] = float(np.mean(cs)) if cs else float("nan")
    return out


# ------------------------------------------------------------------ the page

def dropped_text(dropped: pd.DataFrame) -> str:
    if dropped.empty:
        return "No company-date held more than {:.0%} of the panel's cap.".format(MAX_CAP_SHARE)
    items = ", ".join(f"{esc(str(r.ticker))} {r.asof} ({r.share:.0%})" for r in dropped.itertuples())
    return (f"{len(dropped)} company-dates held more than {MAX_CAP_SHARE:.0%} of the panel's cap on their date, a share count "
            f"the ladder's guards could not refuse or a split between the price's month end and the cover page, and are "
            f"left out of the cap-weighted legs: {items}.")


def build_html(results: pd.DataFrame, agree: dict, legs: dict, priced: dict[str, dict[int, float]],
               cap_share: float, ff_last: str, today: dt.date, dropped: pd.DataFrame | None = None) -> str:
    names = dict(FACTORS)
    universes = [u for u in UNIVERSES if u in set(results.universe)]
    split_label = f"{SPLIT_YM[:4]}-{SPLIT_YM[4:]}"

    def lookup(u, m, freq, factor, weighting):
        g = results[(results.universe == u) & (results.method == m) & (results.freq == freq)
                    & (results.factor == factor) & (results.weighting == weighting)]
        return None if g.empty else g.iloc[0]

    def cell_block(r):
        if r is None:
            return "<td></td><td></td><td></td><td></td>"
        return (f"<td>{pct(r['raw_ann'])}</td>{tcell(r['raw_t'])}"
                f"<td>{pct(r['FF5+UMD alpha_ann'])}</td>{tcell(r['FF5+UMD t_alpha'])}")

    method_header = (f"<thead><tr><th rowspan=\"2\">Factor</th><th colspan=\"4\">AQR: z of rank</th>"
                     f"<th colspan=\"4\">MSCI: 5/95 winsorised z</th><th colspan=\"4\">Barra: 3 sd winsorised z</th></tr>"
                     f"<tr>{'<th>Raw ann.</th><th>Raw t</th><th>FF5+UMD α</th><th>α t</th>' * 3}</tr></thead>")

    # Verdict counts per method and weighting.
    counts = {(m, w): summarise_counts(results[(results.method == m) & (results.weighting == w)].to_dict("records"))
              for m in METHODS for w in ("cw", "vw")}
    n_sorts = counts[("aqr", "cw")]["n"]
    piv = results[results.weighting == "cw"].pivot_table(index=["universe", "freq", "factor"], columns="method",
                                                        values="FF5+UMD t_alpha")
    same_sign = int((np.sign(piv).nunique(axis=1) == 1).sum())

    def verdict(w):
        parts = []
        for m, (label, _) in METHODS.items():
            c = counts[(m, w)]
            parts.append(f"{label} {c['sig_alpha']} of {c['n']} ({c['sig_alpha_pos']} positive), "
                         f"{c['positive']} spreads positive, mean alpha t {c['mean_alpha_t']:.2f}")
        return "; ".join(parts)

    # Composite tables.
    comp_rows, comp_vw_rows, ew_rows = [], [], []
    for u in universes:
        for freq in FREQS:
            comp_rows.append(f"<tr><td>{LABEL[u]}</td><td>{freq}</td>"
                             + "".join(cell_block(lookup(u, m, freq, "composite", "cw")) for m in METHODS) + "</tr>")
            cells = []
            for m in METHODS:
                for w in ("cw", "vw"):
                    r = lookup(u, m, freq, "composite", w)
                    cells.append("<td></td><td></td>" if r is None else f"<td>{pct(r['raw_ann'])}</td>{tcell(r['FF5+UMD t_alpha'])}")
            comp_vw_rows.append(f"<tr><td>{LABEL[u]}</td><td>{freq}</td>{''.join(cells)}</tr>")
        cells = []
        for freq in FREQS:
            for m in METHODS:
                r = lookup(u, m, freq, "composite", "ew")
                cells.append(tcell(None if r is None else r["FF5+UMD t_alpha"]))
        ew_rows.append(f"<tr><td>{LABEL[u]}</td>{''.join(cells)}</tr>")

    # The legs, equal- against cap-weighted, before and from the split.
    leg_rows = []
    for u in universes:
        for label, title in (("before", f"to {split_label}"), ("from", f"from {split_label}")):
            L = legs[u][label]
            leg_rows.append(f"<tr><td>{LABEL[u]}</td><td>{title} ({L['months']} mo)</td>"
                            + "".join(f"<td>{pct(L[c])}</td>" for c in ("long_cw", "short_cw", "spread_cw", "long_vw", "short_vw", "spread_vw"))
                            + "</tr>")

    # Every sort past 2 under any method, either weighting.
    sig_rows = []
    for w in ("cw", "vw"):
        pv = results[results.weighting == w].pivot_table(index=["universe", "freq", "factor"], columns="method",
                                                        values="FF5+UMD t_alpha")
        for (u, freq, factor), r in pv[(pv.abs() >= 2).any(axis=1)].iterrows():
            sig_rows.append(f"<tr><td>{LABEL[u]}</td><td>{esc(names[factor])}</td><td>{freq}</td><td>{'equal' if w == 'cw' else 'cap'}</td>"
                            + "".join(tcell(r[m]) for m in METHODS) + "</tr>")

    # Per-universe tables, one per schedule and weighting.
    uni_sections = []
    for u in universes:
        tables = []
        for freq in FREQS:
            for w, wname in (("cw", "equal-weighted"), ("vw", "cap-weighted")):
                body = []
                for factor, name in FACTORS:
                    body.append(f"<tr><td>{esc(name)}</td>"
                                + "".join(cell_block(lookup(u, m, freq, factor, w)) for m in METHODS) + "</tr>")
                r = lookup(u, "aqr", freq, "composite", w)
                months = int(r["months"]) if r is not None else 0
                tables.append(f"""<h3>{LABEL[u]}, {freq} rebalancing, {wname} ({months} months)</h3>
<div class="wrap"><table>{method_header}<tbody>{''.join(body)}</tbody></table></div>""")
        ag, agv = agree[u]["cw"], agree[u]["vw"]
        pq = priced.get(u, {})
        pq_note = (f" Survivorship, measured on the stored index-wide composite: {pq.get(1, float('nan')):.0f}% of bottom-quintile "
                   f"name-dates have a return the following month, {pq.get(5, float('nan')):.0f}% of the top." if pq else "")
        uni_sections.append(f"""<h2>{LABEL[u]}</h2>
<p>Agreement between methods on the composite, the mean correlation of its monthly spread series over the three schedules: equal-weighted AQR–MSCI {num(ag[('aqr', 'msci')])}, AQR–Barra {num(ag[('aqr', 'barra')])}, MSCI–Barra {num(ag[('msci', 'barra')])}; cap-weighted {num(agv[('aqr', 'msci')])}, {num(agv[('aqr', 'barra')])}, {num(agv[('msci', 'barra')])}.{pq_note}</p>
{''.join(tables)}""")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Three scoring methods, sector-neutral, {today.isoformat()}</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>Three ways to score, one sector-neutral sort, two weightings</h1>
<p class="sub">The same nine point-in-time accounting factors and composite, scored the AQR way, the MSCI way and the Barra way within each sector, sorted long the top fifth and short the bottom fifth of every sector, held equal-weighted and cap-weighted, measured raw and against Fama-French five factors plus momentum. Generated {today.isoformat()} from the database by <code>tools/score_methods.py</code>. Nothing here was written to the database.</p>

<div class="verdict">
<p><b>The choice of scoring method does not change the answer.</b> For a single factor the three scores order a sector's members identically, so the nine single-factor sorts are the same under all three by construction; only the composite, where the scale of each score decides how the nine combine, can differ, and it differs little. Equal-weighted, sorts clearing |t| 2 on FF5+UMD: {verdict('cw')}. The alpha's sign agrees under all three methods in {same_sign} of {n_sorts} sorts.</p>
<p><b>Cap weighting changes the size of the recent drag, not its direction.</b> Cap-weighted: {verdict('vw')}. Section 3 shows the legs: what the long and short books earned equal- and cap-weighted before and from {split_label}.</p>
</div>

<h2>1. The three methods and the three weightings, exactly</h2>
<ul>
<li><b>AQR</b> (Asness, Frazzini and Pedersen 2019, <i>Quality Minus Junk</i>): within each (date, sector) group each factor is converted to ranks and the ranks are standardised to a z-score; the composite is the mean of a member's available scores (four or more), standardised again within the group. Ranks make the score immune to outliers, which is the paper's stated reason.</li>
<li><b>MSCI</b> (MSCI Quality Indexes Methodology, May 2022, as in its sector-neutral variant): within each group the raw value is winsorised at the 5th and 95th percentile ranks, then z-scored with the group's mean and standard deviation; the composite is the simple average of the z-scores. Magnitude survives: a company far ahead on a ratio scores further ahead.</li>
<li><b>Barra</b> (MSCI FaCS / Barra fundamental factor models): within each group the raw value is winsorised at the mean ± 3 standard deviations, then standardised; descriptors combined linearly and the combination re-standardised. Two departures here: the mean is equal-weighted where Barra uses a cap-weighted mean, and the winsorisation is a single pass where Barra iterates a robust mean.</li>
</ul>
<p>Why the single-factor results coincide: within a (date, sector) group, the rank, the 5/95-winsorised value and the 3 sd-winsorised value are all non-decreasing functions of the raw value, and the clipping only ties members already inside the top or bottom fifth, so each method puts the same members in each quintile. The methods differ in the composite because a z-score of ranks is bounded and evenly spaced while a z-score of winsorised values keeps the distance between members, so a company far ahead on one factor pulls further ahead on the average.</p>
<ul>
<li><b>Equal-weighted</b> (the headline): every stock in a sector's top fifth has the same weight, so does every stock in its bottom fifth; the sector spreads are averaged with member-count weights. That is an equal-weighted long book against an equal-weighted short book with the sector mix matched on both sides.</li>
<li><b>Cap-weighted</b>: within each sector's top fifth and bottom fifth stocks are weighted by market cap on the rebalance date (<code>sec_market.market_cap_at</code>: the month-end close before the date times the cover-page shares knowable on it); the sector spreads are averaged with each sector's share of the universe's market cap that date, the same weights on both sides. A member without a market cap, {100 - cap_share:.1f}% of company-dates, mostly early years before a cover-page share count is knowable, drops out of the cap-weighted legs only.</li>
<li><b>Equal sectors</b>: as the headline but every sector's spread counts the same, utilities as much as industrials; shown for the composite only, since small sectors make it noisy.</li>
</ul>
<p>Everything else is held fixed: the signed factor values from <code>sec_market.factor_panel</code> (revenue growth negated, so a higher score always means the higher expected return in the literature); sectors with fewer than {MIN_SECTOR} scored members on a date left out; within each sector five equal buckets by score; holding to the next rebalance date with the ticker the spine assigns on the rebalance date, exactly as <code>sec_market.backtest</code> does; alphas from a regression of the monthly spread on the French factors with Newey-West (six lags) standard errors; French vintage {ff_last}.</p>

<h2>2. The composite, side by side</h2>
<h3>Equal-weighted</h3>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Schedule</th><th colspan="4">AQR: z of rank</th><th colspan="4">MSCI: 5/95 winsorised z</th><th colspan="4">Barra: 3 sd winsorised z</th></tr>
<tr>{'<th>Raw ann.</th><th>Raw t</th><th>FF5+UMD α</th><th>α t</th>' * 3}</tr></thead>
<tbody>{''.join(comp_rows)}</tbody></table></div>
<p class="note">Cells are shaded when |t| ≥ 2 (strong) or ≥ 1.65 (faint). Raw t is the plain mean over its standard error; alpha t is Newey-West.</p>

<h3>Equal-weighted against cap-weighted</h3>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Schedule</th><th colspan="4">AQR</th><th colspan="4">MSCI</th><th colspan="4">Barra</th></tr>
<tr>{'<th>EW raw</th><th>EW α t</th><th>VW raw</th><th>VW α t</th>' * 3}</tr></thead>
<tbody>{''.join(comp_vw_rows)}</tbody></table></div>
<p class="note">EW = equal-weighted (the headline), VW = cap-weighted. Raw spread annualised and the FF5+UMD alpha t.</p>

<h3>The other aggregation: sectors weighted equally</h3>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th colspan="3">Monthly, α t</th><th colspan="3">Quarterly, α t</th><th colspan="3">Annual, α t</th></tr>
<tr>{'<th>AQR</th><th>MSCI</th><th>Barra</th>' * 3}</tr></thead>
<tbody>{''.join(ew_rows)}</tbody></table></div>

<h2>3. What cap weighting changes: the legs</h2>
<p>The composite, AQR scoring, monthly rebalancing. The annualised return of the long book (every sector's top fifth) and the short book (every sector's bottom fifth), and their difference, equal-weighted and cap-weighted, before and from {split_label}, the month the Fama-French profitability factor turned. The split is descriptive, not fitted.</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Period</th><th colspan="3">Equal-weighted</th><th colspan="3">Cap-weighted</th></tr>
<tr><th>Long</th><th>Short</th><th>Spread</th><th>Long</th><th>Short</th><th>Spread</th></tr></thead>
<tbody>{''.join(leg_rows)}</tbody></table></div>
<p class="note">Read across a row: if the cap-weighted long book beats the equal-weighted one, the largest high-quality names led; if the cap-weighted short book trails the equal-weighted one, the rally in low-quality names was in the small ones. The spread is long minus short.</p>

<h2>4. Every sort that clears |t| 2 under any method</h2>
<div class="wrap"><table>
<thead><tr><th>Universe</th><th>Factor</th><th>Schedule</th><th>Weighting</th><th>AQR α t</th><th>MSCI α t</th><th>Barra α t</th></tr></thead>
<tbody>{''.join(sig_rows) if sig_rows else '<tr><td colspan="7">none</td></tr>'}</tbody></table></div>
<p class="note">FF5+UMD alpha t under each method for any sort where at least one method reaches |t| 2, equal- or cap-weighted. With {n_sorts} sorts per method and weighting, about {max(1, round(n_sorts * 0.05))} are expected past 2 from noise alone.</p>

<h2>5. Every factor, every universe</h2>
{''.join(uni_sections)}

<h2>6. What to read into this, and what not to</h2>
<ul>
<li><b>Survivors only.</b> Prices exist only for tickers still listed, so the bottom quintile is missing the names that failed or were bought, and their absent returns flatter the short leg. This biases every spread here downward and is the agreed next data step; no scoring method or weighting repairs it.</li>
<li><b>One regime.</b> The profitability sorts were flat to slightly positive through 2024 and lost from {split_label}, when the Fama-French profitability factor itself reversed. The three methods inherit that equally; the two weightings inherit it in different sizes, which section 3 measures.</li>
<li><b>Ranks and winsorised values order companies almost identically.</b> The agreement correlations are the measurement; the methods differ in whether magnitude beyond order carries information, and in these universes it carries none that survives the factor models.</li>
<li><b>Cap weighting is point-in-time but approximate.</b> One price for every class, the primary ticker's, so a dual-class issuer with a differently priced second class is approximate; and a member with no knowable share count on the date is absent from the cap-weighted legs. Share counts a thousand-fold off their own filing's net income over EPS, or contradicted that far by the filer's nearby filings, are refused by the ladder (<code>sec_gold.shares_outstanding_at</code>, check 74). {dropped_text(dropped if dropped is not None else pd.DataFrame())}</li>
</ul>
<p class="note">Related: the four per-universe backtest pages and the overview (<code>tools/factor_report.py</code>) use the index-wide percentile sort; <code>tools/ff_baseline.py</code> is the regression code shared here.</p>
</main>
</body>
</html>
"""


def build_variants_html(results: dict[str, pd.DataFrame], legs: dict, shares: dict, ff_last: str, today: dt.date,
                        dropped: pd.DataFrame | None = None) -> str:
    """The three variants side by side: the composite, the counts over every
    sort, the legs, where the industry groups land, every sort past |t| 2."""
    names = dict(FACTORS)
    variants = [v for v in VARIANTS if v in results]
    universes = [u for u in UNIVERSES if u in set(results["sector"].universe)]
    split_label = f"{SPLIT_YM[:4]}-{SPLIT_YM[4:]}"
    hu = "SP1500" if "SP1500" in universes else universes[-1]
    groups_text = ", ".join(f"{name} {lo}" + (f"–{hi}" if hi != lo else "") for name, lo, hi in INDUSTRY_GROUPS)

    def lookup(v, u, m, freq, factor, weighting):
        r = results[v]
        g = r[(r.universe == u) & (r.method == m) & (r.freq == freq) & (r.factor == factor) & (r.weighting == weighting)]
        return None if g.empty else g.iloc[0]

    counts = {(v, m, w): summarise_counts(results[v][(results[v].method == m) & (results[v].weighting == w)].to_dict("records"))
              for v in variants for m in METHODS for w in ("cw", "vw")}

    def count_text(m, w):
        parts = []
        for v in variants:
            c = counts[(v, m, w)]
            parts.append(f"{VARIANTS[v][0]} {c['sig_alpha']} of {c['n']} ({c['sig_alpha_pos']} positive), "
                         f"{c['positive']} spreads positive, mean alpha t {c['mean_alpha_t']:.2f}")
        return "; ".join(parts)

    # 1. Where the industry groups land.
    share_rows = []
    for u in universes:
        ind = {r["group"]: r for r in shares.get("industry", {}).get(u, [])}
        for r in shares.get("sector", {}).get(u, []):
            i = ind.get(r["group"])
            share_rows.append(f"<tr><td>{LABEL[u]}</td><td>{esc(r['group'])}</td><td>{r['company_months']:,}</td>"
                              f"<td>{r['pct_bottom']:.0f}%</td><td>{r['pct_top']:.0f}%</td>"
                              + (f"<td>{i['pct_bottom']:.0f}%</td><td>{i['pct_top']:.0f}%</td>" if i else "<td></td><td></td>") + "</tr>")
    banks = {v: next((r for r in shares.get(v, {}).get(hu, []) if r["group"] == INDUSTRY_GROUPS[0][0]), None) for v in ("sector", "industry")}
    banks_text = ""
    if banks["sector"] and banks["industry"]:
        banks_text = (f" In the {LABEL[hu]}, {banks['sector']['pct_bottom']:.0f}% of bank company-months sat in the sector's bottom fifth and "
                      f"{banks['sector']['pct_top']:.0f}% in its top under sector-relative scoring; industry-relative, "
                      f"{banks['industry']['pct_bottom']:.0f}% and {banks['industry']['pct_top']:.0f}%.")

    # 2. The composite side by side.
    comp_rows = []
    for u in universes:
        for freq in FREQS:
            cells = []
            for v in variants:
                for w in ("cw", "vw"):
                    r = lookup(v, u, "aqr", freq, "composite", w)
                    cells.append("<td></td><td></td>" if r is None else f"<td>{pct(r['raw_ann'])}</td>{tcell(r['FF5+UMD t_alpha'])}")
            comp_rows.append(f"<tr><td>{LABEL[u]}</td><td>{freq}</td>{''.join(cells)}</tr>")
    head_text = []
    for v in variants:
        r_ew, r_vw = lookup(v, hu, "aqr", "monthly", "composite", "cw"), lookup(v, hu, "aqr", "monthly", "composite", "vw")
        if r_ew is not None and r_vw is not None:
            head_text.append(f"{VARIANTS[v][0]} {pct(r_ew['raw_ann'])} (alpha t {r_ew['FF5+UMD t_alpha']:.2f}) equal-weighted, "
                             f"{pct(r_vw['raw_ann'])} (t {r_vw['FF5+UMD t_alpha']:.2f}) cap-weighted")

    # 3. The counts.
    count_rows = []
    for v in variants:
        for m, (mlabel, _) in METHODS.items():
            cells = []
            for w in ("cw", "vw"):
                c = counts[(v, m, w)]
                cells.append(f"<td>{c['sig_alpha']}</td><td>{c['sig_alpha_pos']}</td><td>{c['positive']}</td><td>{num(c['mean_alpha_t'])}</td>")
            count_rows.append(f"<tr><td>{VARIANTS[v][0]}</td><td>{mlabel}</td>{''.join(cells)}</tr>")
    n_sorts = counts[(variants[0], "aqr", "cw")]["n"]

    # 4. The legs.
    leg_rows = []
    for u in universes:
        for label, title in (("before", f"to {split_label}"), ("from", f"from {split_label}")):
            for v in variants:
                L = legs[v][u][label]
                leg_rows.append(f"<tr><td>{LABEL[u]}</td><td>{title} ({L['months']} mo)</td><td>{VARIANTS[v][0]}</td>"
                                + "".join(f"<td>{pct(L[c])}</td>" for c in ("long_cw", "short_cw", "spread_cw", "long_vw", "short_vw", "spread_vw"))
                                + "</tr>")

    # 5. Every sort past |t| 2 under any variant, AQR scoring.
    sig_rows = []
    factor_order = [f for f, _ in FACTORS]
    for w in ("cw", "vw"):
        piv = {v: results[v][(results[v].weighting == w) & (results[v].method == "aqr")]
               .set_index(["universe", "freq", "factor"])["FF5+UMD t_alpha"] for v in variants}
        keys = set()
        for v in variants:
            keys |= set(piv[v][piv[v].abs() >= 2].index)
        for u, freq, factor in sorted(keys, key=lambda k: (UNIVERSES.index(k[0]), FREQS.index(k[1]), factor_order.index(k[2]))):
            sig_rows.append(f"<tr><td>{LABEL[u]}</td><td>{esc(names[factor])}</td><td>{freq}</td><td>{'equal' if w == 'cw' else 'cap'}</td>"
                            + "".join(tcell(piv[v].get((u, freq, factor), None)) for v in variants) + "</tr>")

    variant_head = "".join(f"<th colspan=\"4\">{VARIANTS[v][0]}</th>" for v in variants)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Financials scored within their industry, {today.isoformat()}</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>Financials scored within their industry, beside the ex-Financials control</h1>
<p class="sub">The strict sector-neutral sort of <code>docs/reports/score_methods_sector_neutral_{today.isoformat()}.html</code> run three ways: scoring within the sector as shipped; scoring a Financials member within its industry group (banks, insurance, REITs, financial services, by SIC code) with the sort still within the sector; and the academic control that drops Financials and Real Estate before scoring. Generated {today.isoformat()} from the database by <code>tools/score_methods.py --variants</code>. Nothing here was written to the database.</p>

<div class="verdict">
<p><b>Where Financials members land.</b>{banks_text} Section 1 has every group and universe.</p>
<p><b>The {LABEL[hu]} composite, monthly, AQR scoring:</b> {"; ".join(head_text)}.</p>
<p><b>Over every sort, equal-weighted, AQR scoring, clearing |t| 2 on FF5+UMD:</b> {count_text("aqr", "cw")}. <b>Cap-weighted:</b> {count_text("aqr", "vw")}. Section 3 has the three methods.</p>
</div>

<h2>What the three variants are, exactly</h2>
<ul>
<li><b>Sector-relative</b>: every measure standardised within its (date, GICS sector) group, the composite the mean of a member's available scores re-standardised within the sector, quintiles within the sector. The shipped construction.</li>
<li><b>Industry-relative</b>: for members of {INDUSTRY_SECTOR}, every measure standardised within the (date, industry group) instead, the group by the filer's SIC code (<code>sec_reference.company.sic_latest</code>: {groups_text}, {INDUSTRY_OTHER} otherwise); the composite, the mean of those group-relative scores, re-standardised within the sector as before, which leaves the order within the sector unchanged; the sort unchanged, quintiles within the sector. A group with fewer than {MIN_GROUP} members on a date, or a member without a SIC, is scored within the sector as before. REITs are a group only while the dated panel files them under {INDUSTRY_SECTOR}, before the 2016-09 GICS change made Real Estate a sector. Every other sector is scored as in the sector-relative variant.</li>
<li><b>ex-Financials and Real Estate</b>: both sectors dropped before scoring, the GICS form of the academic rule that excludes SIC 6000–6999 (Fama and French 1992, Novy-Marx 2013). Everything else unchanged.</li>
</ul>
<p>The SIC code is the one on the company's latest filing; a bank is a bank throughout, so for this purpose it is stable. Scoring groups by industry instead of sector is what systematic managers do when a sector mixes balance-sheet businesses with asset-light ones; the industry-specific descriptors they add (return on tangible equity, efficiency ratio, combined ratio, funds from operations) are not built here, so a bank is still scored on the measures the panel has, three of which divide by assets.</p>

<h2>1. Where each industry group lands in {INDUSTRY_SECTOR}'s quintiles</h2>
<p>The composite, AQR scoring, every date: the share of each group's company-months in the sector's bottom fifth and its top fifth. A sort that treats the groups alike puts 20% in each.</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Group</th><th rowspan="2">Company-months</th><th colspan="2">Sector-relative</th><th colspan="2">Industry-relative</th></tr>
<tr><th>Bottom fifth</th><th>Top fifth</th><th>Bottom fifth</th><th>Top fifth</th></tr></thead>
<tbody>{''.join(share_rows)}</tbody></table></div>

<h2>2. The composite, side by side</h2>
<p>AQR scoring. The raw annualised spread and the FF5+UMD alpha t, equal-weighted (EW) and cap-weighted (VW), under each variant. The MSCI and Barra scorings are in the CSV files.</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Schedule</th>{variant_head}</tr>
<tr>{'<th>EW raw</th><th>EW α t</th><th>VW raw</th><th>VW α t</th>' * len(variants)}</tr></thead>
<tbody>{''.join(comp_rows)}</tbody></table></div>
<p class="note">Cells are shaded when |t| ≥ 2 (strong) or ≥ 1.65 (faint).</p>

<h2>3. Over every sort</h2>
<p>Of the {n_sorts} sorts per variant, method and weighting (every factor and the composite, three schedules, the universes above): how many clear |t| 2 on FF5+UMD, how many of those are positive, how many spreads are positive, the mean alpha t. About {max(1, round(n_sorts * 0.05))} past 2 are expected from noise alone.</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Variant</th><th rowspan="2">Method</th><th colspan="4">Equal-weighted</th><th colspan="4">Cap-weighted</th></tr>
<tr>{'<th>|t| ≥ 2</th><th>of them positive</th><th>Spreads positive</th><th>Mean α t</th>' * 2}</tr></thead>
<tbody>{''.join(count_rows)}</tbody></table></div>

<h2>4. The legs</h2>
<p>The composite, AQR scoring, monthly rebalancing: the annualised return of the long book and the short book and their difference, equal- and cap-weighted, before and from {split_label}, under each variant.</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Period</th><th rowspan="2">Variant</th><th colspan="3">Equal-weighted</th><th colspan="3">Cap-weighted</th></tr>
<tr><th>Long</th><th>Short</th><th>Spread</th><th>Long</th><th>Short</th><th>Spread</th></tr></thead>
<tbody>{''.join(leg_rows)}</tbody></table></div>

<h2>5. Every sort that clears |t| 2 under any variant</h2>
<div class="wrap"><table>
<thead><tr><th>Universe</th><th>Factor</th><th>Schedule</th><th>Weighting</th>{''.join(f'<th>{VARIANTS[v][0]} α t</th>' for v in variants)}</tr></thead>
<tbody>{''.join(sig_rows) if sig_rows else '<tr><td colspan="7">none</td></tr>'}</tbody></table></div>
<p class="note">AQR scoring, FF5+UMD alpha t under each variant for any sort where at least one variant reaches |t| 2.</p>

<h2>6. What this does and does not settle</h2>
<ul>
<li><b>It separates the groups; it does not change what a bank is scored on.</b> A bank still has no gross profit and no operating margin in the panel, and three of its seven measures divide by assets. The next two steps, not built here: score banks and insurers only on the measures that mean the same thing across financials (return on equity, its quarterly form, revenue growth, earnings surprise), an allowlist rule by SIC prefix; then the descriptors their own analysts use (return on tangible equity, pre-provision profit to assets, efficiency ratio, provisions to loans, the combined ratio, funds from operations for REITs), each a formula variant keyed by SIC prefix in the concept layer.</li>
<li><b>Survivors only.</b> Unchanged from the sector-neutral page: no delisted company has a price series, so every short leg here is flattered.</li>
<li><b>Real Estate has the same shape.</b> Sorted across the whole universe, Real Estate members land in the bottom fifth far more often than the top; sector neutrality handles that, and inside the sector nearly every member is a REIT, so an industry split does nothing there. Funds from operations is the fix.</li>
<li><b>Cap weighting rests on guarded share counts.</b> {dropped_text(dropped if dropped is not None else pd.DataFrame())}</li>
<li><b>Dropping the sectors is a control, not a construction.</b> The ex-Financials variant says how much of the sector-neutral result the two sectors carried; it is not a recommendation to run without them.</li>
</ul>
<p class="note">French vintage {ff_last}. Related: <code>docs/reports/score_methods_sector_neutral_{today.isoformat()}.html</code> (the shipped sort, every factor and method), <code>tools/ff_baseline.py</code> (the regression code).</p>
</main>
</body>
</html>
"""


def statistics(universes: list[str], frames: dict, ff: pd.DataFrame):
    """Every spread's statistics, the agreement, the legs and the monthly
    series for one variant, from run_universe's frames per universe."""
    rows, agree, legs, series = [], {}, {}, {}
    for u in universes:
        parts = []
        for m, df in frames[u].items():
            parts.append(df.assign(method=m))
            for (freq, factor), g in df.groupby(["freq", "factor"]):
                for weighting in WEIGHTINGS:
                    rec = regress(g.set_index("ym")[f"spread_{weighting}"], ff)
                    if rec is None:
                        continue
                    rec.update({"universe": u, "method": m, "freq": freq, "factor": factor, "weighting": weighting,
                                "sectors_mean": float(g["n_sectors"].mean())})
                    rows.append(rec)
        agree[u] = {"cw": agreement(frames[u], "spread_cw"), "vw": agreement(frames[u], "spread_vw")}
        legs[u] = legs_by_period(frames[u]["aqr"])
        series[u] = pd.concat(parts, ignore_index=True)
    return pd.DataFrame(rows), agree, legs, series


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--universes", default=",".join(UNIVERSES))
    ap.add_argument("--ff-dir", default=str(config.PROJECT_ROOT / "data" / "external" / "french"))
    ap.add_argument("--out-dir", default=str(config.PROJECT_ROOT / "docs" / "reports"))
    ap.add_argument("--variants", action="store_true",
                    help="also run the industry-relative and the ex-Financials variants and write the comparison page")
    args = ap.parse_args()
    ff_dir = Path(args.ff_dir)
    ff = load_french(ff_dir)
    ff_last = ff.index.max()
    universes = [u.strip() for u in args.universes.split(",") if u.strip()]
    today = dt.date.today()

    cap = ensure_cap_cache(ff_dir / "market_cap_panel.csv")
    cap, dropped = drop_dominant_caps(cap)
    if len(dropped):
        with db.get_conn() as conn, conn.cursor() as cur:
            cur.execute("SELECT d.asof, d.cik, sec_reference.ticker_at(d.cik, d.asof) FROM unnest(%s::date[], %s::int[]) AS d(asof, cik)",
                        (list(dropped["asof"]), [int(c) for c in dropped["cik"]]))
            tickers = {(a, c): t for a, c, t in cur.fetchall()}
        dropped["ticker"] = [tickers.get((a, int(c))) or str(c) for a, c in zip(dropped["asof"], dropped["cik"])]
        print("market cap: left out as dominant: " + ", ".join(f"{r.ticker} {r.asof} ({r.share:.0%})" for r in dropped.itertuples()))
    cap_share = 100.0 * cap["market_cap"].notna().mean()

    variants = list(VARIANTS) if args.variants else ["sector"]
    frames, shares = {}, {}
    with ThreadPoolExecutor(max_workers=len(universes)) as ex:
        for v in variants:
            frames[v] = dict(zip(universes, ex.map(lambda u, v=v: run_universe(u, cap, v), universes)))
            if args.variants and not VARIANTS[v][2]:
                shares[v] = dict(zip(universes, ex.map(lambda u, v=v: group_shares(u, v), universes)))
            print(f"{VARIANTS[v][0]}: sorts done")
        priced = dict(zip(universes, ex.map(priced_by_quintile, universes)))

    results, agree, legs = {}, {}, {}
    for v in variants:
        results[v], agree[v], legs[v], series = statistics(universes, frames[v], ff)
        suffix = "" if v == "sector" else f"_{v}"
        for u in universes:
            results[v][results[v].universe == u].to_csv(ff_dir / f"score_methods_{u}{suffix}.csv", index=False)
            series[u].to_csv(ff_dir / f"score_methods_series_{u}{suffix}.csv", index=False)
        print(f"written {ff_dir}/score_methods_<universe>{suffix}.csv and the series files")

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"score_methods_sector_neutral_{today.isoformat()}.html"
    out_path.write_text(build_html(results["sector"], agree["sector"], legs["sector"], priced, cap_share, ff_last, today, dropped))
    print(f"written {out_path}")
    if args.variants:
        out_path = out_dir / f"score_methods_financials_{today.isoformat()}.html"
        out_path.write_text(build_variants_html(results, legs, shares, ff_last, today, dropped))
        print(f"written {out_path}")

    pd.set_option("display.width", 250)
    for v in variants:
        show = results[v][results[v].factor == "composite"].pivot_table(index=["universe", "freq"], columns=["weighting", "method"],
                                                                        values="FF5+UMD t_alpha")
        print(f"--- {VARIANTS[v][0]}: composite FF5+UMD alpha t")
        print(show.to_string(float_format=lambda x: f"{x:7.2f}"))
        for u in universes:
            L = legs[v][u]
            print(f"{u} composite monthly legs, from {SPLIT_YM}: EW long {L['from']['long_cw']:+.1%} short {L['from']['short_cw']:+.1%} "
                  f"| VW long {L['from']['long_vw']:+.1%} short {L['from']['short_vw']:+.1%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
