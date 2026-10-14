"""Three ways to score a factor, sector-neutral, side by side.

The same nine accounting factors and the same composite, scored three ways
within each (date, GICS sector) group of a universe's factor panel:

  aqr    z-score of the RANK (Asness, Frazzini and Pedersen 2019, "Quality
         Minus Junk": ranks, standardised, averaged, re-standardised)
  msci   the raw value winsorised at the 5th and 95th percentile of the
         group, then z-scored (MSCI Quality Indexes Methodology, May 2022)
  barra  the raw value winsorised at the group mean +/- 3 standard
         deviations, then z-scored (MSCI FaCS / Barra; here with an
         equal-weighted mean and a single winsorisation pass, since the
         panel carries no market capitalisation)

The composite is the mean of a member's available factor scores (four or
more), re-standardised within the group. The sort is the strict sector-
neutral one: within each sector on each rebalance date, quintiles by
score; the sector's spread is its equal-weight top fifth minus its bottom
fifth; the universe spread is the average of sector spreads weighted by
member count (dollar-neutral by sector), with the equal-sector-weight
average kept beside it. Sectors with fewer than ten scored members on a
date are left out. Holding and return matching are exactly those of
sec_market.backtest (held to the next rebalance, the ticker the spine
assigns on the rebalance date).

Every spread is measured raw and against FF5 and FF5 + UMD with
Newey-West (six lags) t-statistics, with the code of tools/ff_baseline.py.
Nothing is written to the database.

Usage:
  uv run python tools/score_methods.py                 # all four universes
  uv run python tools/score_methods.py --universes SP500,SP1500
Writes <ff-dir>/score_methods_<universe>.csv (every statistic, both sector
weightings) and docs/reports/score_methods_sector_neutral_<date>.html.
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
FACTORS = [
    ("composite", "Composite"), ("gp_at", "Gross profit / assets"), ("ocf_at", "Operating cash flow / assets"),
    ("roa", "Return on assets"), ("roe", "Return on equity"), ("operating_margin", "Operating margin"),
    ("revenue_growth", "Revenue growth (low is good)"), ("roe_q", "Quarterly ROE"), ("roa_q", "Quarterly ROA"),
    ("sue", "Earnings surprise (SUE)"),
]
FREQS = ["monthly", "quarterly", "annual"]
MIN_SECTOR = 10

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
         sec_reference.ticker_at(s.cik, w.rebalance_date) AS ticker_then,
         count(*) OVER (PARTITION BY w.freq, s.factor, w.rebalance_date, s.gics_sector) AS sector_n
  FROM windows w JOIN sig s ON s.asof = w.rebalance_date WHERE s.signal IS NOT NULL),
sorted AS (
  SELECT m.*, NTILE(5) OVER (PARTITION BY m.freq, m.factor, m.rebalance_date, m.gics_sector ORDER BY m.signal, m.cik) AS bucket
  FROM members m WHERE m.sector_n >= %(min_sector)s),
held AS (
  SELECT s.freq, s.factor, s.gics_sector, s.bucket, r.month_end, r.ret_1m
  FROM sorted s JOIN sec_market.monthly_return r
    ON r.cik = s.cik AND r.month_end > s.rebalance_date AND r.month_end <= COALESCE(s.next_rebalance, s.rebalance_date + 400)
   AND r.ticker = COALESCE(s.ticker_then, r.ticker)
  WHERE s.bucket IN (1, 5) AND r.ret_1m IS NOT NULL),
sector_month AS (
  SELECT freq, factor, month_end, gics_sector,
         avg(ret_1m) FILTER (WHERE bucket = 5) - avg(ret_1m) FILTER (WHERE bucket = 1) AS sector_spread, count(*) AS n_names
  FROM held GROUP BY 1, 2, 3, 4)
SELECT freq, factor, month_end,
       sum(sector_spread * n_names) / sum(n_names) AS spread_cw, avg(sector_spread) AS spread_ew, count(*) AS n_sectors
FROM sector_month WHERE sector_spread IS NOT NULL GROUP BY 1, 2, 3 ORDER BY 1, 2, 3
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


def run_universe(u: str) -> dict[str, pd.DataFrame]:
    out = {}
    with db.get_conn() as conn:
        for m in METHODS:
            with conn.cursor() as cur:
                cur.execute(SQL, {"u": u, "m": m, "min_sector": MIN_SECTOR})
                rows = cur.fetchall()
            df = pd.DataFrame(rows, columns=["freq", "factor", "month_end", "spread_cw", "spread_ew", "n_sectors"])
            for c in ("spread_cw", "spread_ew"):
                df[c] = df[c].astype(float)
            df["ym"] = pd.to_datetime(df["month_end"]).dt.strftime("%Y%m")
            out[m] = df
    return out


def priced_by_quintile(u: str) -> dict[int, float]:
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(SQL_PRICED, {"u": u})
        return {int(b): float(p) for b, p in cur.fetchall()}


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


def agreement(frames: dict[str, pd.DataFrame], weighting: str, factor: str = "composite") -> dict[tuple[str, str], float]:
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
                j = ga.set_index("ym")[weighting].to_frame("a").join(gb.set_index("ym")[weighting].to_frame("b"), how="inner")
                if len(j) >= 24 and j["a"].std() > 0 and j["b"].std() > 0:
                    cs.append(float(j["a"].corr(j["b"])))
            out[(a, b)] = float(np.mean(cs)) if cs else float("nan")
    return out


def build_html(results: pd.DataFrame, agree: dict, priced: dict[str, dict[int, float]], ff_last: str,
               today: dt.date) -> str:
    cw = results[results.weighting == "cw"]
    names = dict(FACTORS)
    universes = [u for u in UNIVERSES if u in set(cw.universe)]

    def cell_block(r):
        if r is None:
            return "<td></td><td></td><td></td><td></td>"
        return (f"<td>{pct(r['raw_ann'])}</td>{tcell(r['raw_t'])}"
                f"<td>{pct(r['FF5+UMD alpha_ann'])}</td>{tcell(r['FF5+UMD t_alpha'])}")

    def lookup(u, m, freq, factor):
        g = cw[(cw.universe == u) & (cw.method == m) & (cw.freq == freq) & (cw.factor == factor)]
        return None if g.empty else g.iloc[0]

    # Summary counts per method, over every sort in every universe.
    counts = {m: summarise_counts(cw[cw.method == m].to_dict("records")) for m in METHODS}
    n_sorts = counts["aqr"]["n"]
    # Alpha sign agreement across the three methods.
    piv = cw.pivot_table(index=["universe", "freq", "factor"], columns="method", values="FF5+UMD t_alpha")
    same_sign = int((np.sign(piv).nunique(axis=1) == 1).sum())
    any_sig_all = piv[(piv.abs() >= 2).any(axis=1)]

    sig_rows = []
    for (u, freq, factor), r in any_sig_all.iterrows():
        sig_rows.append(f"<tr><td>{LABEL[u]}</td><td>{esc(names[factor])}</td><td>{freq}</td>"
                        + "".join(tcell(r[m]) for m in METHODS) + "</tr>")

    # Composite side by side.
    comp_rows = []
    for u in universes:
        for freq in FREQS:
            comp_rows.append(f"<tr><td>{LABEL[u]}</td><td>{freq}</td>"
                             + "".join(cell_block(lookup(u, m, freq, "composite")) for m in METHODS) + "</tr>")

    # Equal-sector-weight composite, the other aggregation, alpha t only.
    ew = results[(results.weighting == "ew") & (results.factor == "composite")]
    ew_rows = []
    for u in universes:
        cells = []
        for freq in FREQS:
            for m in METHODS:
                g = ew[(ew.universe == u) & (ew.method == m) & (ew.freq == freq)]
                cells.append(tcell(None if g.empty else g.iloc[0]["FF5+UMD t_alpha"]))
        ew_rows.append(f"<tr><td>{LABEL[u]}</td>{''.join(cells)}</tr>")

    # Per-universe tables, one per schedule.
    uni_sections = []
    for u in universes:
        tables = []
        for freq in FREQS:
            body = []
            for factor, name in FACTORS:
                body.append(f"<tr><td>{esc(name)}</td>" + "".join(cell_block(lookup(u, m, freq, factor)) for m in METHODS) + "</tr>")
            months = lookup(u, "aqr", freq, "composite")
            months = int(months["months"]) if months is not None else 0
            tables.append(f"""<h3>{LABEL[u]}, {freq} rebalancing ({months} months)</h3>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Factor</th><th colspan="4">AQR: z of rank</th><th colspan="4">MSCI: 5/95 winsorised z</th><th colspan="4">Barra: 3 sd winsorised z</th></tr>
<tr>{'<th>Raw ann.</th><th>Raw t</th><th>FF5+UMD α</th><th>α t</th>' * 3}</tr></thead>
<tbody>{''.join(body)}</tbody></table></div>""")
        ag = agree[u]
        pq = priced.get(u, {})
        pq_note = (f" Survivorship, measured on the stored index-wide composite: {pq.get(1, float('nan')):.0f}% of bottom-quintile "
                   f"name-dates have a return the following month, {pq.get(5, float('nan')):.0f}% of the top." if pq else "")
        uni_sections.append(f"""<h2>{LABEL[u]}</h2>
<p>Agreement between methods on the composite, the mean correlation of its monthly spread series over the three schedules: AQR–MSCI {num(ag[('aqr', 'msci')])}, AQR–Barra {num(ag[('aqr', 'barra')])}, MSCI–Barra {num(ag[('msci', 'barra')])}.{pq_note}</p>
{''.join(tables)}""")

    def verdict():
        parts = []
        for m, (label, _) in METHODS.items():
            c = counts[m]
            parts.append(f"{label}: {c['sig_alpha']} of {c['n']} sorts clear |t| 2 on FF5+UMD ({c['sig_alpha_pos']} positive), "
                         f"{c['positive']} spreads positive, mean alpha t {c['mean_alpha_t']:.2f}")
        return "; ".join(parts) + "."

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
<h1>Three ways to score, one sector-neutral sort</h1>
<p class="sub">The same nine point-in-time accounting factors and composite, scored the AQR way, the MSCI way and the Barra way within each sector, sorted long the top fifth and short the bottom fifth of every sector, measured raw and against Fama-French five factors plus momentum. Generated {today.isoformat()} from the database by <code>tools/score_methods.py</code>. Nothing here was written to the database.</p>

<div class="verdict">
<p><b>The choice of scoring method does not change the answer.</b> For a single factor the three scores order a sector's members identically, so the nine single-factor sorts are the same under all three by construction; only the composite, where the scale of each score decides how the nine combine, can differ, and it differs little. {verdict()} Across the {n_sorts} sorts the sign of the FF5+UMD alpha agrees under all three methods in {same_sign} of {n_sorts}.</p>
</div>

<h2>1. The three methods, exactly</h2>
<ul>
<li><b>AQR</b> (Asness, Frazzini and Pedersen 2019, <i>Quality Minus Junk</i>): within each (date, sector) group each factor is converted to ranks and the ranks are standardised to a z-score; the composite is the mean of a member's available scores (four or more), standardised again within the group. Ranks make the score immune to outliers, which is the paper's stated reason.</li>
<li><b>MSCI</b> (MSCI Quality Indexes Methodology, May 2022, as in its sector-neutral variant): within each group the raw value is winsorised at the 5th and 95th percentile ranks, then z-scored with the group's mean and standard deviation; the composite is the simple average of the z-scores. Magnitude survives: a company far ahead on a ratio scores further ahead.</li>
<li><b>Barra</b> (MSCI FaCS / Barra fundamental factor models): within each group the raw value is winsorised at the mean ± 3 standard deviations, then standardised; descriptors combined linearly and the combination re-standardised. Two departures here, because the panel carries no market capitalisation: the mean is equal-weighted where Barra uses a cap-weighted mean, and the winsorisation is a single pass where Barra iterates a robust mean.</li>
</ul>
<p>Why the single-factor results coincide: within a (date, sector) group, the rank, the 5/95-winsorised value and the 3 sd-winsorised value are all non-decreasing functions of the raw value, and the clipping only ties members already inside the top or bottom fifth, so each method puts the same members in each quintile. The methods differ in the composite because a z-score of ranks is bounded and evenly spaced while a z-score of winsorised values keeps the distance between members, so a company far ahead on one factor pulls further ahead on the average.</p>
<p>Everything else is held fixed across the three: the signed factor values from <code>sec_market.factor_panel</code> (revenue growth negated, so a higher score always means the higher expected return in the literature); sectors with fewer than {MIN_SECTOR} scored members on a date left out; within each sector five equal buckets by score; equal weight within a bucket; the sector's spread its top fifth minus its bottom fifth; the universe spread the sector spreads weighted by member count, so the long and short sides carry identical sector counts; holding to the next rebalance date with the ticker the spine assigns on the rebalance date, exactly as <code>sec_market.backtest</code> does; alphas from a regression of the monthly spread on the French factors with Newey-West (six lags) standard errors; French vintage {ff_last}.</p>

<h2>2. The composite, side by side</h2>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th rowspan="2">Schedule</th><th colspan="4">AQR: z of rank</th><th colspan="4">MSCI: 5/95 winsorised z</th><th colspan="4">Barra: 3 sd winsorised z</th></tr>
<tr>{'<th>Raw ann.</th><th>Raw t</th><th>FF5+UMD α</th><th>α t</th>' * 3}</tr></thead>
<tbody>{''.join(comp_rows)}</tbody></table></div>
<p class="note">Cells are shaded when |t| ≥ 2 (strong) or ≥ 1.65 (faint). Raw t is the plain mean over its standard error; alpha t is Newey-West.</p>

<h3>The other aggregation: sectors weighted equally</h3>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Universe</th><th colspan="3">Monthly, α t</th><th colspan="3">Quarterly, α t</th><th colspan="3">Annual, α t</th></tr>
<tr>{'<th>AQR</th><th>MSCI</th><th>Barra</th>' * 3}</tr></thead>
<tbody>{''.join(ew_rows)}</tbody></table></div>
<p class="note">The composite's FF5+UMD alpha t when every sector's spread counts the same, utilities as much as industrials. Small sectors are noisier, so this version is more volatile; it is not the headline construction.</p>

<h2>3. Every sort that clears |t| 2 under any method</h2>
<div class="wrap"><table>
<thead><tr><th>Universe</th><th>Factor</th><th>Schedule</th><th>AQR α t</th><th>MSCI α t</th><th>Barra α t</th></tr></thead>
<tbody>{''.join(sig_rows) if sig_rows else '<tr><td colspan="6">none</td></tr>'}</tbody></table></div>
<p class="note">FF5+UMD alpha t under each method for any sort where at least one method reaches |t| 2. With {n_sorts} sorts per method, about {max(1, round(n_sorts * 0.05))} are expected past 2 from noise alone.</p>

<h2>4. Every factor, every universe</h2>
{''.join(uni_sections)}

<h2>5. What to read into this, and what not to</h2>
<ul>
<li><b>Survivors only.</b> Prices exist only for tickers still listed, so the bottom quintile is missing the names that failed or were bought, and their absent returns flatter the short leg. This biases every spread here downward and is the agreed next data step; no scoring method can repair it.</li>
<li><b>One regime.</b> The profitability sorts were flat to slightly positive through 2024 and lost heavily from 2025, when the Fama-French profitability factor itself reversed. The three methods inherit that equally.</li>
<li><b>Ranks and winsorised values order companies almost identically.</b> The agreement correlations above are the measurement; the methods differ in whether magnitude beyond order carries information, and in these universes it carries none that survives the factor models.</li>
<li><b>Equal weights, no size control.</b> Within a bucket every company counts the same; the long-short carries a negative market beta and a small-cap tilt that the factor models absorb and the raw spreads do not.</li>
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

    with ThreadPoolExecutor(max_workers=len(universes)) as ex:
        frames = dict(zip(universes, ex.map(run_universe, universes)))
        priced = dict(zip(universes, ex.map(priced_by_quintile, universes)))

    rows = []
    agree = {}
    for u in universes:
        for m, df in frames[u].items():
            for (freq, factor), g in df.groupby(["freq", "factor"]):
                for weighting in ("cw", "ew"):
                    rec = regress(g.set_index("ym")[f"spread_{weighting}"], ff)
                    if rec is None:
                        continue
                    rec.update({"universe": u, "method": m, "freq": freq, "factor": factor, "weighting": weighting,
                                "sectors_mean": float(g["n_sectors"].mean())})
                    rows.append(rec)
        agree[u] = agreement(frames[u], "spread_cw")
        out = pd.DataFrame([r for r in rows if r["universe"] == u])
        out.to_csv(ff_dir / f"score_methods_{u}.csv", index=False)
        print(f"written {ff_dir / f'score_methods_{u}.csv'}")
    results = pd.DataFrame(rows)

    html = build_html(results, agree, priced, ff_last, today)
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"score_methods_sector_neutral_{today.isoformat()}.html"
    out_path.write_text(html)
    print(f"written {out_path}")

    cw = results[results.weighting == "cw"]
    pd.set_option("display.width", 250)
    show = cw[cw.factor == "composite"].pivot_table(index=["universe", "freq"], columns="method",
                                                    values=["raw_ann", "FF5+UMD t_alpha"])
    print(show.to_string(float_format=lambda v: f"{v:7.3f}"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
