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
A member without a market cap drops out of the cap-weighted legs only.
Sectors with fewer than ten scored members on a date are left out.
Holding and return matching are exactly those of sec_market.backtest
(held to the next rebalance, the ticker the spine assigns on the
rebalance date).

Every spread is measured raw and against FF5 and FF5 + UMD with
Newey-West (six lags) t-statistics, with the code of tools/ff_baseline.py.
Nothing is written to the database.

Usage:
  uv run python tools/score_methods.py                 # all four universes
  uv run python tools/score_methods.py --universes SP500,SP1500
Writes <ff-dir>/score_methods_<universe>.csv (every statistic, every
weighting), <ff-dir>/score_methods_series_<universe>.csv (the monthly
legs and spreads) and docs/reports/score_methods_sector_neutral_<date>.html.
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

SQL = """
WITH p AS (
  SELECT asof, cik, gics_sector, gp_at, ocf_at, roa, roe, operating_margin, -revenue_growth AS revenue_growth, roe_q, roa_q, sue
  FROM sec_market.factor_panel WHERE index_name = %(u)s AND gics_sector IS NOT NULL),
long AS (
  SELECT p.asof, p.cik, p.gics_sector, f.factor, f.val
  FROM p, LATERAL (VALUES ('gp_at', p.gp_at), ('ocf_at', p.ocf_at), ('roa', p.roa), ('roe', p.roe),
                   ('operating_margin', p.operating_margin), ('revenue_growth', p.revenue_growth),
                   ('roe_q', p.roe_q), ('roa_q', p.roa_q), ('sue', p.sue)) AS f(factor, val)
  WHERE f.val IS NOT NULL),
grp AS (
  SELECT asof, gics_sector, factor,
         percentile_cont(0.05) WITHIN GROUP (ORDER BY val) AS p5, percentile_cont(0.95) WITHIN GROUP (ORDER BY val) AS p95,
         avg(val) AS mu, stddev_samp(val) AS sd
  FROM long GROUP BY 1, 2, 3),
ranked AS (SELECT l.*, rank() OVER (PARTITION BY asof, gics_sector, factor ORDER BY val) AS rk FROM long l),
x AS (
  SELECT r.asof, r.cik, r.gics_sector, r.factor,
         CASE %(m)s WHEN 'aqr'   THEN r.rk::numeric
                   WHEN 'msci'  THEN LEAST(g.p95, GREATEST(g.p5, r.val))
                   WHEN 'barra' THEN LEAST(g.mu + 3 * g.sd, GREATEST(g.mu - 3 * g.sd, r.val)) END AS v
  FROM ranked r JOIN grp g USING (asof, gics_sector, factor)),
z AS (
  SELECT asof, cik, gics_sector, factor, (v - avg(v) OVER w) / NULLIF(stddev_samp(v) OVER w, 0) AS z
  FROM x WINDOW w AS (PARTITION BY asof, gics_sector, factor)),
comp AS (SELECT asof, cik, gics_sector, avg(z) AS z FROM z WHERE z IS NOT NULL GROUP BY 1, 2, 3 HAVING count(z) >= 4),
sig AS (
  SELECT asof, cik, gics_sector, factor, z AS signal FROM z
  UNION ALL
  SELECT asof, cik, gics_sector, 'composite', (z - avg(z) OVER w) / NULLIF(stddev_samp(z) OVER w, 0)
  FROM comp WINDOW w AS (PARTITION BY asof, gics_sector)),
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

def run_universe(u: str, cap: pd.DataFrame) -> dict[str, pd.DataFrame]:
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
                cur.execute(SQL, {"u": u, "m": m, "min_sector": MIN_SECTOR})
                rows = cur.fetchall()
            df = pd.DataFrame(rows, columns=["freq", "factor", "month_end", "spread_cw", "long_cw", "short_cw",
                                             "spread_ew", "spread_vw", "long_vw", "short_vw", "n_sectors"])
            for c in df.columns[3:10]:
                df[c] = df[c].astype(float)
            df["ym"] = pd.to_datetime(df["month_end"]).dt.strftime("%Y%m")
            out[m] = df
    return out


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

def build_html(results: pd.DataFrame, agree: dict, legs: dict, priced: dict[str, dict[int, float]],
               cap_share: float, ff_last: str, today: dt.date) -> str:
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
<li><b>Cap weighting is point-in-time but approximate.</b> One price for every class, the primary ticker's, so a dual-class issuer with a differently priced second class is approximate; and a member with no knowable share count on the date is absent from the cap-weighted legs.</li>
</ul>
<p class="note">Related: the four per-universe backtest pages and the overview (<code>tools/factor_report.py</code>) use the index-wide percentile sort; <code>tools/ff_baseline.py</code> is the regression code shared here.</p>
</main>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--universes", default=",".join(UNIVERSES))
    ap.add_argument("--ff-dir", default=str(config.PROJECT_ROOT / "data" / "external" / "french"))
    ap.add_argument("--out-dir", default=str(config.PROJECT_ROOT / "docs" / "reports"))
    args = ap.parse_args()
    ff_dir = Path(args.ff_dir)
    ff = load_french(ff_dir)
    ff_last = ff.index.max()
    universes = [u.strip() for u in args.universes.split(",") if u.strip()]
    today = dt.date.today()

    cap = ensure_cap_cache(ff_dir / "market_cap_panel.csv")
    cap_share = 100.0 * cap["market_cap"].notna().mean()

    with ThreadPoolExecutor(max_workers=len(universes)) as ex:
        frames = dict(zip(universes, ex.map(lambda u: run_universe(u, cap), universes)))
        priced = dict(zip(universes, ex.map(priced_by_quintile, universes)))

    rows = []
    agree, legs = {}, {}
    for u in universes:
        series = []
        for m, df in frames[u].items():
            series.append(df.assign(method=m))
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
        pd.DataFrame([r for r in rows if r["universe"] == u]).to_csv(ff_dir / f"score_methods_{u}.csv", index=False)
        pd.concat(series, ignore_index=True).to_csv(ff_dir / f"score_methods_series_{u}.csv", index=False)
        print(f"written {ff_dir / f'score_methods_{u}.csv'} and the series file")
    results = pd.DataFrame(rows)

    html = build_html(results, agree, legs, priced, cap_share, ff_last, today)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"score_methods_sector_neutral_{today.isoformat()}.html"
    out_path.write_text(html)
    print(f"written {out_path}")

    pd.set_option("display.width", 250)
    show = results[results.factor == "composite"].pivot_table(index=["universe", "freq"], columns=["weighting", "method"],
                                                              values="FF5+UMD t_alpha")
    print(show.to_string(float_format=lambda v: f"{v:7.2f}"))
    for u in universes:
        L = legs[u]
        print(f"{u} composite monthly legs, from {SPLIT_YM}: EW long {L['from']['long_cw']:+.1%} short {L['from']['short_cw']:+.1%} "
              f"| VW long {L['from']['long_vw']:+.1%} short {L['from']['short_vw']:+.1%}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
