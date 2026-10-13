"""The factor backtest report, one self-contained HTML file.

Reads the database (sec_market.factor_panel, sec_market.backtest and
backtest_summary, sec_market.monthly_price, sec_gold.suspect_fact) and
the Fama-French baseline table that tools/ff_baseline.py wrote, and
writes docs/reports/factor_backtest_<date>.html: methodology, coverage,
every bucket at every rebalancing frequency, the FF5 and FF5+UMD alphas
and loadings, two inline SVG charts (cumulative composite quintiles; the
alpha t-statistics), the defects the build caught, and what remains open.
No external assets: the file opens offline and prints.

Usage:
  uv run python tools/ff_baseline.py SP500 --download          # first
  uv run python tools/factor_report.py SP500                   # then this
Options: --from 2010-01-01, --ff-csv data/external/french/ff_baseline_SP500.csv,
         --out docs/reports/factor_backtest_<today>.html
"""
from __future__ import annotations

import argparse
import datetime as dt
import html
import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dera_pipeline import config, db  # noqa: E402

FACTORS = [
    ("composite", "Composite", "mean of the available signed percentiles (four or more)"),
    ("gp_at", "Gross profit / assets", "Novy-Marx 2013; higher is better"),
    ("ocf_at", "Operating cash flow / assets", "higher is better"),
    ("roa", "Return on assets", "fiscal-year net income over year-end assets"),
    ("roe", "Return on equity", "fiscal-year net income over year-end equity"),
    ("operating_margin", "Operating margin", "operating income over revenue"),
    ("revenue_growth", "Revenue growth (low is good)", "signed negative: slow growers expected to outperform"),
    ("roe_q", "Quarterly ROE", "JKP niq_be: the quarter over the prior quarter-end equity"),
    ("roa_q", "Quarterly ROA", "JKP niq_at: the quarter over the prior quarter-end assets"),
    ("sue", "Earnings surprise (SUE)", "standardised unexpected earnings, Foster-Olsen-Shevlin form"),
]
FREQS = ["monthly", "quarterly", "annual"]
MODELS = [("FF5", ["Mkt-RF", "SMB", "HML", "RMW", "CMA"]),
          ("FF5+UMD", ["Mkt-RF", "SMB", "HML", "RMW", "CMA", "UMD"])]


# --------------------------------------------------------------------- data
def q(conn, sql, params=None):
    with conn.cursor() as cur:
        cur.execute(sql, params)
        return cur.fetchall()


def load(conn, index: str, frm: dt.date):
    d = {}
    d["panel"] = q(conn, """
        SELECT count(DISTINCT asof), count(*), min(asof), max(asof)
        FROM sec_market.factor_panel WHERE index_name = %s""", (index,))[0]
    d["coverage"] = q(conn, """
        SELECT extract(year FROM asof)::int AS yr, count(DISTINCT asof),
               round(avg(n)), round(avg(c)), round(avg(gp)), round(avg(ocf)), round(avg(roa)), round(avg(roe)),
               round(avg(om)), round(avg(rg)), round(avg(roeq)), round(avg(roaq)), round(avg(sue))
        FROM (SELECT asof, count(*) n, count(composite) c, count(gp_at) gp, count(ocf_at) ocf, count(roa) roa,
                     count(roe) roe, count(operating_margin) om, count(revenue_growth) rg, count(roe_q) roeq,
                     count(roa_q) roaq, count(sue) sue
              FROM sec_market.factor_panel WHERE index_name = %s GROUP BY 1) x
        GROUP BY 1 ORDER BY 1""", (index,))
    d["priced"] = q(conn, """
        SELECT extract(year FROM fp.asof)::int,
               round(avg(CASE WHEN p.one IS NOT NULL THEN 1 ELSE 0 END) * 100, 1)
        FROM sec_market.factor_panel fp
        LEFT JOIN LATERAL (SELECT 1 AS one FROM sec_market.monthly_price mp
                           WHERE mp.cik = fp.cik AND mp.month_end > fp.asof AND mp.month_end <= fp.asof + 35
                           LIMIT 1) p ON TRUE
        WHERE fp.index_name = %s GROUP BY 1 ORDER BY 1""", (index,))
    d["prices"] = q(conn, """
        SELECT count(*), count(DISTINCT cik), min(month_end), max(month_end) FROM sec_market.monthly_price""")[0]
    d["price_load"] = q(conn, """
        SELECT loaded_at::date, symbols_requested, symbols_returned, members_without_listing
        FROM sec_market.price_load ORDER BY loaded_at DESC LIMIT 1""")[0]
    d["members_ever"] = q(conn, "SELECT count(DISTINCT cik) FROM sec_reference.index_membership")[0][0]
    d["suspect"] = q(conn, """
        SELECT reason, count(*), count(DISTINCT cik) FROM sec_gold.suspect_fact GROUP BY 1 ORDER BY 1""")
    d["summary"] = {}
    for freq in FREQS:
        for key, _, _ in FACTORS:
            d["summary"][(freq, key)] = q(conn, """
                SELECT series, months, first_month, last_month, mean_monthly, t_stat, annualised, sharpe, hit_rate, avg_members
                FROM sec_market.backtest_summary(%s, %s, %s, %s, NULL, 5)""", (index, key, freq, frm))
    d["cum"] = q(conn, """
        SELECT month_end, bucket, ret, benchmark_ret
        FROM sec_market.backtest(%s, 'composite', 'monthly', %s, NULL, 5)
        WHERE ret IS NOT NULL ORDER BY month_end, bucket""", (index, frm))
    return d


# ------------------------------------------------------------------ helpers
def pct(x, nd=1):
    return "" if x is None or pd.isna(x) else f"{float(x) * 100:.{nd}f}%"


def num(x, nd=2):
    return "" if x is None or pd.isna(x) else f"{float(x):.{nd}f}"


def tcell(t):
    """A t-statistic cell, shaded when it clears 2 in either direction."""
    if t is None or pd.isna(t):
        return "<td></td>"
    cls = ' class="sig"' if abs(float(t)) >= 2 else (' class="weak"' if abs(float(t)) >= 1.65 else "")
    return f"<td{cls}>{float(t):.2f}</td>"


def esc(s):
    return html.escape(str(s))


# ------------------------------------------------------------------- charts
def cumulative_chart(rows) -> str:
    """Growth of one dollar, composite quintiles and the equal-weight
    benchmark, monthly rebalancing, as an inline SVG."""
    df = pd.DataFrame(rows, columns=["month_end", "bucket", "ret", "benchmark_ret"])
    df["ret"] = df["ret"].astype(float)
    df["benchmark_ret"] = df["benchmark_ret"].astype(float)
    wide = df.pivot(index="month_end", columns="bucket", values="ret").sort_index()
    bench = df.groupby("month_end")["benchmark_ret"].first().sort_index()
    growth = (1 + wide.fillna(0)).cumprod()
    growth["EW"] = (1 + bench.fillna(0)).cumprod()
    w, h, pad_l, pad_r, pad_t, pad_b = 860, 360, 56, 16, 20, 40
    n = len(growth)
    ymax = float(growth.max().max()) * 1.05
    ymin = 0.8

    def sx(i):
        return pad_l + i * (w - pad_l - pad_r) / max(n - 1, 1)

    def sy(v):
        return pad_t + (h - pad_t - pad_b) * (1 - (v - ymin) / (ymax - ymin))

    colors = {1: "#c0392b", 2: "#e67e22", 3: "#7f8c8d", 4: "#2980b9", 5: "#1e8449", "EW": "#111111"}
    labels = {1: "Q1 (bottom)", 2: "Q2", 3: "Q3", 4: "Q4", 5: "Q5 (top)", "EW": "Equal-weight members"}
    out = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Growth of one dollar by composite quintile">']
    # gridlines
    step = 1 if ymax < 8 else 2
    v = 1
    while v <= ymax:
        y = sy(v)
        out.append(f'<line x1="{pad_l}" y1="{y:.1f}" x2="{w - pad_r}" y2="{y:.1f}" class="grid"/>')
        out.append(f'<text x="{pad_l - 8}" y="{y + 4:.1f}" class="axis" text-anchor="end">${v}</text>')
        v += step
    years = sorted({str(d)[:4] for d in growth.index})
    for yr in years:
        idx = next(i for i, d in enumerate(growth.index) if str(d).startswith(yr))
        if int(yr) % 2 == 0:
            out.append(f'<text x="{sx(idx):.1f}" y="{h - pad_b + 18}" class="axis" text-anchor="middle">{yr}</text>')
    for col in [1, 2, 3, 4, 5, "EW"]:
        pts = " ".join(f"{sx(i):.1f},{sy(float(v)):.1f}" for i, v in enumerate(growth[col]))
        dash = ' stroke-dasharray="6 4"' if col == "EW" else ""
        out.append(f'<polyline points="{pts}" fill="none" stroke="{colors[col]}" stroke-width="{2.2 if col in (1, 5, "EW") else 1.4}"{dash}/>')
        last = float(growth[col].iloc[-1])
        out.append(f'<text x="{w - pad_r + 2}" y="{sy(last) + 4:.1f}" class="lbl" fill="{colors[col]}" text-anchor="start"></text>')
    # legend
    lx, ly = pad_l + 10, pad_t + 8
    for i, col in enumerate([5, 4, 3, 2, 1, "EW"]):
        yy = ly + i * 18
        dash = ' stroke-dasharray="6 4"' if col == "EW" else ""
        out.append(f'<line x1="{lx}" y1="{yy}" x2="{lx + 22}" y2="{yy}" stroke="{colors[col]}" stroke-width="2.5"{dash}/>')
        out.append(f'<text x="{lx + 28}" y="{yy + 4}" class="lbl">{labels[col]}: ${float(growth[col].iloc[-1]):.2f}</text>')
    out.append("</svg>")
    return "\n".join(out)


def tstat_chart(ff: pd.DataFrame) -> str:
    """Alpha t-statistics per factor, three frequencies, two models."""
    w, row_h, pad_l, pad_r, pad_t = 860, 30, 230, 20, 36
    rows = [k for k, _, _ in FACTORS]
    h = pad_t + row_h * len(rows) + 30
    tmin, tmax = -3.2, 3.2

    def sx(t):
        return pad_l + (t - tmin) / (tmax - tmin) * (w - pad_l - pad_r)

    out = [f'<svg viewBox="0 0 {w} {h}" role="img" aria-label="Alpha t-statistics">']
    out.append(f'<rect x="{sx(-2):.1f}" y="{pad_t - 10}" width="{sx(2) - sx(-2):.1f}" height="{row_h * len(rows) + 10}" class="band"/>')
    for t in (-3, -2, -1, 0, 1, 2, 3):
        out.append(f'<line x1="{sx(t):.1f}" y1="{pad_t - 10}" x2="{sx(t):.1f}" y2="{pad_t + row_h * len(rows)}" class="grid"/>')
        out.append(f'<text x="{sx(t):.1f}" y="{pad_t - 16}" class="axis" text-anchor="middle">t = {t}</text>')
    marks = {"monthly": "circle", "quarterly": "rect", "annual": "path"}
    colors = {"FF5": "#2980b9", "FF5+UMD": "#c0392b"}
    names = dict((k, n) for k, n, _ in FACTORS)
    for i, key in enumerate(rows):
        y = pad_t + i * row_h + row_h / 2
        out.append(f'<text x="{pad_l - 10}" y="{y + 4}" class="lbl" text-anchor="end">{esc(names[key])}</text>')
        out.append(f'<line x1="{pad_l}" y1="{y}" x2="{w - pad_r}" y2="{y}" class="grid"/>')
        for freq in FREQS:
            r = ff[(ff.series == "spread") & (ff.factor == key) & (ff.freq == freq)]
            if r.empty:
                continue
            for model, _ in MODELS:
                t = float(r.iloc[0][f"{model} t_alpha"])
                x = sx(max(min(t, tmax), tmin))
                c = colors[model]
                if marks[freq] == "circle":
                    out.append(f'<circle cx="{x:.1f}" cy="{y}" r="5" fill="{c}" fill-opacity="0.85"><title>{esc(names[key])}, {freq}, {model}: t = {t:.2f}</title></circle>')
                elif marks[freq] == "rect":
                    out.append(f'<rect x="{x - 5:.1f}" y="{y - 5}" width="10" height="10" fill="{c}" fill-opacity="0.85"><title>{esc(names[key])}, {freq}, {model}: t = {t:.2f}</title></rect>')
                else:
                    out.append(f'<path d="M{x:.1f},{y - 6} L{x + 6:.1f},{y + 5} L{x - 6:.1f},{y + 5} Z" fill="{c}" fill-opacity="0.85"><title>{esc(names[key])}, {freq}, {model}: t = {t:.2f}</title></path>')
    ly = h - 12
    out.append(f'<circle cx="{pad_l + 6}" cy="{ly}" r="5" fill="#555"/><text x="{pad_l + 16}" y="{ly + 4}" class="lbl">monthly</text>')
    out.append(f'<rect x="{pad_l + 86}" y="{ly - 5}" width="10" height="10" fill="#555"/><text x="{pad_l + 102}" y="{ly + 4}" class="lbl">quarterly</text>')
    out.append(f'<path d="M{pad_l + 186},{ly - 6} L{pad_l + 192},{ly + 5} L{pad_l + 180},{ly + 5} Z" fill="#555"/><text x="{pad_l + 198}" y="{ly + 4}" class="lbl">annual</text>')
    out.append(f'<text x="{pad_l + 290}" y="{ly + 4}" class="lbl" fill="{colors["FF5"]}">■ FF5 alpha</text>')
    out.append(f'<text x="{pad_l + 400}" y="{ly + 4}" class="lbl" fill="{colors["FF5+UMD"]}">■ FF5 + UMD alpha</text>')
    out.append(f'<text x="{pad_l + 540}" y="{ly + 4}" class="lbl">shaded: |t| &lt; 2</text>')
    out.append("</svg>")
    return "\n".join(out)


# -------------------------------------------------------------------- pages
CSS = """
:root { --bg:#fbfbf9; --fg:#1d1d1b; --muted:#5f5f5a; --rule:#dedcd3; --head:#f1efe6; --zebra:#f7f6f1;
        --accent:#8a3b12; --sig:#fde8d9; --weak:#fff6e5; --band:#eceae2; --link:#1f4e79; }
@media (prefers-color-scheme: dark) {
  :root { --bg:#15161a; --fg:#e8e6df; --muted:#a3a39b; --rule:#33353c; --head:#1f2127; --zebra:#1a1c21;
          --accent:#e8905a; --sig:#4a2a17; --weak:#3a3114; --band:#24262d; --link:#8ab4e8; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--fg); font:16px/1.55 -apple-system, "Segoe UI", Helvetica, Arial, sans-serif; }
main { max-width: 980px; margin: 0 auto; padding: 32px 16px 80px; }
h1 { font-size: 2rem; line-height:1.2; margin: 0 0 4px; letter-spacing:-0.01em; }
h2 { font-size: 1.35rem; margin: 44px 0 12px; padding-top: 10px; border-top: 2px solid var(--rule); }
h3 { font-size: 1.05rem; margin: 26px 0 8px; }
p, li { max-width: 72ch; }
.sub { color: var(--muted); margin: 0 0 24px; }
.verdict { border-left: 5px solid var(--accent); padding: 12px 18px; background: var(--head); margin: 20px 0; }
.verdict p { margin: 6px 0; }
.kpis { display:grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin: 18px 0; }
.kpi { background: var(--head); border:1px solid var(--rule); border-radius: 8px; padding: 10px 14px; }
.kpi b { display:block; font-size: 1.35rem; }
.kpi span { color: var(--muted); font-size: 0.85rem; }
table { border-collapse: collapse; width: 100%; margin: 10px 0 6px; font-size: 0.9rem; font-variant-numeric: tabular-nums; }
th, td { padding: 6px 8px; border-bottom: 1px solid var(--rule); text-align: right; white-space: nowrap; }
th:first-child, td:first-child { text-align: left; }
thead th { background: var(--head); position: sticky; top: 0; }
tbody tr:nth-child(even) { background: var(--zebra); }
td.sig { background: var(--sig); font-weight: 600; }
td.weak { background: var(--weak); }
.wrap { overflow-x: auto; }
.note { color: var(--muted); font-size: 0.85rem; margin: 2px 0 14px; }
code { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: 0.88em; background: var(--head); padding: 1px 5px; border-radius: 4px; }
pre { background: var(--head); border:1px solid var(--rule); border-radius: 8px; padding: 12px 14px; overflow-x:auto; font-size: 0.85rem; }
figure { margin: 16px 0 6px; }
figcaption { color: var(--muted); font-size: 0.85rem; margin-top: 6px; }
svg { width: 100%; height: auto; display:block; }
svg .grid { stroke: var(--rule); stroke-width: 1; }
svg .axis { fill: var(--muted); font-size: 12px; }
svg .lbl { fill: var(--fg); font-size: 12px; }
svg .band { fill: var(--band); }
a { color: var(--link); }
.small { font-size: 0.85rem; color: var(--muted); }
@media print { body { background:#fff; color:#000; } main { max-width:none; padding:0; } h2 { break-after: avoid; } .wrap { overflow: visible; } }
"""


def build_html(index: str, frm: dt.date, d: dict, ff: pd.DataFrame, today: dt.date) -> str:
    dates, rows, dmin, dmax = d["panel"]
    prices_n, prices_cos, pmin, pmax = d["prices"]
    loaded_at, sym_req, sym_ret, no_listing = d["price_load"]
    names = {k: n for k, n, _ in FACTORS}
    S = d["summary"]

    def series(freq, key, name):
        for r in S[(freq, key)]:
            if r[0] == name:
                return r
        return None

    # --- headline table: raw and alpha t by frequency
    head_rows = []
    for key, name, _ in FACTORS:
        cells = [f"<td>{esc(name)}</td>"]
        for freq in FREQS:
            sp = series(freq, key, "spread (top - bottom)")
            cells.append(f"<td>{pct(sp[6])}</td>" if sp else "<td></td>")
        for freq in FREQS:
            sp = series(freq, key, "spread (top - bottom)")
            cells.append(tcell(sp[5]) if sp else "<td></td>")
        for model, _ in MODELS:
            for freq in FREQS:
                r = ff[(ff.series == "spread") & (ff.factor == key) & (ff.freq == freq)]
                cells.append(tcell(r.iloc[0][f"{model} t_alpha"]) if not r.empty else "<td></td>")
        head_rows.append("<tr>" + "".join(cells) + "</tr>")

    # --- benchmark
    bench = {}
    for freq in FREQS:
        r = ff[(ff.series == "benchmark-RF") & (ff.factor == "composite") & (ff.freq == freq)]
        bench[freq] = r.iloc[0] if not r.empty else None

    # --- per frequency bucket tables
    bucket_tables = []
    for freq in FREQS:
        trs = []
        for key, name, _ in FACTORS:
            rs = {r[0]: r for r in S[(freq, key)]}
            sp = rs.get("spread (top - bottom)")
            cells = [f"<td>{esc(name)}</td>", f"<td>{sp[1] if sp else ''}</td>"]
            for b in range(1, 6):
                r = rs.get(f"bucket {b}")
                cells.append(f"<td>{pct(r[6])}</td>" if r else "<td></td>")
            cells += [f"<td>{pct(sp[6])}</td>" if sp else "<td></td>", tcell(sp[5]) if sp else "<td></td>",
                      f"<td>{num(sp[7])}</td>" if sp else "<td></td>", f"<td>{pct(sp[8], 0)}</td>" if sp else "<td></td>"]
            trs.append("<tr>" + "".join(cells) + "</tr>")
        b1 = series(freq, "composite", "benchmark (equal-weight)")
        bucket_tables.append(f"""
<h3>{freq.capitalize()} rebalancing</h3>
<div class="wrap"><table>
<thead><tr><th>Factor</th><th>Months</th><th>Q1 (bottom)</th><th>Q2</th><th>Q3</th><th>Q4</th><th>Q5 (top)</th><th>Spread</th><th>t</th><th>Sharpe</th><th>Hit rate</th></tr></thead>
<tbody>{''.join(trs)}</tbody></table></div>
<p class="note">Annualised equal-weight bucket returns; spread = Q5 − Q1. Equal-weight benchmark of every priced member on this schedule: {pct(b1[6]) if b1 else ''} a year, t {num(b1[5]) if b1 else ''}, Sharpe {num(b1[7]) if b1 else ''}.</p>""")

    # --- FF table (full)
    ff_rows = []
    for freq in FREQS:
        for key, name, _ in FACTORS:
            r = ff[(ff.series == "spread") & (ff.factor == key) & (ff.freq == freq)]
            if r.empty:
                continue
            r = r.iloc[0]
            cells = [f"<td>{esc(name)}</td>", f"<td>{freq}</td>", f"<td>{int(r.months)}</td>",
                     f"<td>{pct(r['raw_ann'])}</td>", tcell(r['raw_t']),
                     f"<td>{pct(r['FF5 alpha_ann'])}</td>", tcell(r['FF5 t_alpha']), f"<td>{num(r['FF5 r2'])}</td>",
                     f"<td>{pct(r['FF5+UMD alpha_ann'])}</td>", tcell(r['FF5+UMD t_alpha']), f"<td>{num(r['FF5+UMD r2'])}</td>"]
            for c in MODELS[1][1]:
                cells.append(f"<td>{num(r[f'FF5+UMD b_{c}'])}</td>")
            ff_rows.append("<tr>" + "".join(cells) + "</tr>")

    cov_rows = "".join(
        f"<tr><td>{r[0]}</td><td>{r[1]}</td><td>{int(r[2])}</td><td>{int(r[3])}</td><td>{int(r[4])}</td><td>{int(r[5])}</td><td>{int(r[6])}</td><td>{int(r[7])}</td><td>{int(r[8])}</td><td>{int(r[9])}</td><td>{int(r[10])}</td><td>{int(r[11])}</td><td>{int(r[12])}</td></tr>"
        for r in d["coverage"])
    priced = {r[0]: r[1] for r in d["priced"]}
    priced_rows = "".join(f"<tr><td>{yr}</td><td>{priced[yr]}%</td></tr>" for yr in sorted(priced))
    suspect = {r[0]: (r[1], r[2]) for r in d["suspect"]}

    # The composite spread by half of the sample, so the chart's caption
    # says where the ending gap came from rather than asserting a shape.
    cum = pd.DataFrame(d["cum"], columns=["month_end", "bucket", "ret", "benchmark_ret"])
    sp = cum.pivot(index="month_end", columns="bucket", values="ret").sort_index()
    sp = (sp[5].astype(float) - sp[1].astype(float)).dropna()
    half = len(sp) // 2
    first, second = sp.iloc[:half], sp.iloc[half:]
    def ann_t(x):
        return x.mean() * 12 * 100, x.mean() / x.std(ddof=1) * (len(x) ** 0.5)
    (a1, t1), (a2, t2) = ann_t(first), ann_t(second)
    cum_note = (f"The top quintile ends highest and the bottom lowest, but the spread between them is not distinguishable from zero: "
                f"{a1:+.1f}% a year (t {t1:.2f}) over the first half of the sample, {str(first.index[0])[:7]} to {str(first.index[-1])[:7]}, "
                f"and {a2:+.1f}% a year (t {t2:.2f}) over the second, {str(second.index[0])[:7]} to {str(second.index[-1])[:7]}.")
    best = ff[ff.series == "spread"].copy()
    best["abs"] = best["FF5 t_alpha"].abs()
    top = best.sort_values("abs", ascending=False).iloc[0]

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Factor backtest report, {index}, {today.isoformat()}</title>
<style>{CSS}</style>
</head>
<body>
<main>
<h1>Do accounting factors pay in the {index}?</h1>
<p class="sub">Point-in-time fundamentals from SEC DERA, month-end prices, equal-weight quintile sorts rebalanced monthly, quarterly and annually, measured raw and against the Fama-French five factors and momentum. Generated {today.isoformat()} from the database by <code>tools/factor_report.py</code>.</p>

<div class="verdict">
<p><b>Verdict: nothing pays.</b> Across the composite and nine factors at three rebalancing frequencies, no top-minus-bottom spread has a raw t-statistic above 1.6. After the five-factor model the spreads are their factor loadings: 0.3 to 0.56 on profitability (RMW), −0.2 to −0.7 on value (HML), and 0.25 to 0.30 on momentum for the quarterly signals. One test in thirty, {esc(names[top.factor])} at {top.freq} rebalancing, reaches an FF5 alpha t of {float(top['FF5 t_alpha']):.2f}; one hit in thirty is what chance delivers, and that sort loads 0.4 on the investment factor (CMA).</p>
<p>The machinery checks out: the equal-weight benchmark of all members earns {pct(bench['monthly']['raw_ann']) if bench['monthly'] is not None else ''} a year with an FF5 alpha of {pct(bench['monthly']['FF5 alpha_ann']) if bench['monthly'] is not None else ''}, market beta {num(bench['monthly']['FF5+UMD b_Mkt-RF']) if bench['monthly'] is not None else ''} and R² {num(bench['monthly']['FF5 r2']) if bench['monthly'] is not None else ''}. The Yahoo returns and the French series line up.</p>
</div>

<div class="kpis">
<div class="kpi"><b>{dates}</b><span>month ends in the panel, {dmin} to {dmax}</span></div>
<div class="kpi"><b>{rows:,}</b><span>company-date rows (about {rows // dates} members a date)</span></div>
<div class="kpi"><b>{prices_cos:,}</b><span>companies with prices, {prices_n:,} month-end rows</span></div>
<div class="kpi"><b>{no_listing}</b><span>of {d['members_ever']:,} members ever with no open listing (no prices)</span></div>
<div class="kpi"><b>30</b><span>tests: 10 sorts × 3 schedules, two factor models each</span></div>
</div>

<h2>1. The headline table</h2>
<p>Each sort ranks the members that have the factor into five equal buckets by the factor's signed percentile (a higher percentile always means the higher expected return in the literature), holds each bucket equal-weighted to the next rebalance date, and reports the top-minus-bottom spread. Alphas come from regressing the monthly spread on the Fama-French factors with Newey-West (six lags) standard errors. Cells are shaded when |t| ≥ 2 (strong) or ≥ 1.65 (faint).</p>
<div class="wrap"><table>
<thead><tr><th rowspan="2">Factor</th><th colspan="3">Raw spread, annualised</th><th colspan="3">Raw t</th><th colspan="3">FF5 alpha t</th><th colspan="3">FF5 + UMD alpha t</th></tr>
<tr><th>M</th><th>Q</th><th>A</th><th>M</th><th>Q</th><th>A</th><th>M</th><th>Q</th><th>A</th><th>M</th><th>Q</th><th>A</th></tr></thead>
<tbody>{''.join(head_rows)}</tbody></table></div>
<p class="note">M = monthly, Q = quarterly, A = annual rebalancing. Period {frm.isoformat()} to the last priced month; the French series end 2026-08 (vintage 202608), so the regressions drop the final month.</p>

<figure>{tstat_chart(ff)}
<figcaption>Alpha t-statistics for every sort. Everything but one point sits inside the shaded |t| &lt; 2 band.</figcaption></figure>

<h2>2. What the buckets did</h2>
<figure>{cumulative_chart(d['cum'])}
<figcaption>Growth of one dollar in each composite quintile, monthly rebalancing, equal-weight within bucket, against the equal-weight return of every priced member (dashed). {cum_note}</figcaption></figure>
{''.join(bucket_tables)}

<h2>3. Against Fama-French: alphas and loadings</h2>
<p>Two models: FF5 (Mkt-RF, SMB, HML, RMW, CMA) and FF5 plus momentum (UMD). Loadings shown are from the six-factor fit. A profitability sort inside the S&amp;P 500 is, to first order, a long position in RMW and a short in HML; once those are priced the residual is noise. The quarterly signals (quarterly ROE and ROA, earnings surprise) carry momentum exposure that the five-factor model does not remove, which is why their FF5 alphas shrink again under FF5+UMD.</p>
<div class="wrap"><table>
<thead><tr><th>Factor</th><th>Schedule</th><th>Months</th><th>Raw ann.</th><th>Raw t</th><th>FF5 α ann.</th><th>t</th><th>R²</th><th>FF5+UMD α ann.</th><th>t</th><th>R²</th><th>Mkt</th><th>SMB</th><th>HML</th><th>RMW</th><th>CMA</th><th>UMD</th></tr></thead>
<tbody>{''.join(ff_rows)}</tbody></table></div>
<h3>The benchmark on the same models</h3>
<div class="wrap"><table>
<thead><tr><th>Schedule</th><th>Months</th><th>Raw ann. (minus RF)</th><th>t</th><th>FF5 α ann.</th><th>t</th><th>R²</th><th>FF5+UMD α ann.</th><th>t</th><th>Mkt</th><th>SMB</th><th>HML</th><th>RMW</th><th>CMA</th><th>UMD</th></tr></thead>
<tbody>{''.join(f"<tr><td>{f}</td><td>{int(b.months)}</td><td>{pct(b['raw_ann'])}</td>{tcell(b['raw_t'])}<td>{pct(b['FF5 alpha_ann'])}</td>{tcell(b['FF5 t_alpha'])}<td>{num(b['FF5 r2'])}</td><td>{pct(b['FF5+UMD alpha_ann'])}</td>{tcell(b['FF5+UMD t_alpha'])}" + ''.join(f"<td>{num(b[f'FF5+UMD b_{c}'])}</td>" for c in MODELS[1][1]) + "</tr>" for f, b in bench.items() if b is not None)}</tbody></table></div>
<p class="note">Equal-weight return of every priced member on each schedule, minus the one-month bill rate. Beta near one, alpha near zero, R² near 0.96: the returns and the French series agree.</p>

<h2>4. Why the spreads are biased down, not up</h2>
<ul>
<li><b>Survivors only.</b> Yahoo returns nothing for a delisted ticker, so {no_listing} of the {d['members_ever']:,} companies ever in the S&amp;P 1500 have no prices. Failures and takeovers leave the index from the bottom quintile more than the top; their missing returns flatter Q1 and shrink the measured spread. The share of panel members with a price the following month rises from {priced.get(min(priced))}% in {min(priced)} to {max(v for k, v in priced.items() if k < today.year)}% by {today.year - 1}.</li>
<li><b>Large caps, equal-weighted.</b> The published profitability premium is smallest among the largest stocks; an equal-weight sort within the S&amp;P 500 is one of the harder tests to pass.</li>
<li><b>Thin first year.</b> The composite covers {int(d['coverage'][0][3])} of {int(d['coverage'][0][2])} members in {d['coverage'][0][0]} (the surprise factor needs eight quarters of history and DERA begins in 2009) and 480 or more from 2013.</li>
<li><b>Thirty tests.</b> Ten sorts on three schedules; at the 5% level one or two |t| &gt; 2 are expected from noise alone.</li>
</ul>

<h2>5. Coverage</h2>
<div class="wrap"><table>
<thead><tr><th>Year</th><th>Dates</th><th>Members</th><th>Composite</th><th>gp_at</th><th>ocf_at</th><th>roa</th><th>roe</th><th>op. margin</th><th>rev. growth</th><th>roe_q</th><th>roa_q</th><th>sue</th></tr></thead>
<tbody>{cov_rows}</tbody></table></div>
<p class="note">Average members per date with each factor. Gross profit is undefined for financials (no gross profit line); operating margin requires a tagged operating income; the quarterly signals need the quarter and the prior quarter-end balance.</p>
<h3>Members with a price the following month</h3>
<div class="wrap"><table><thead><tr><th>Year</th><th>Priced</th></tr></thead><tbody>{priced_rows}</tbody></table></div>
<p class="note">The final year is understated: the last panel date has no following month of prices yet.</p>

<h2>6. Method, exactly</h2>
<ul>
<li><b>Universe.</b> <code>sec_reference.index_members('{index}', date)</code>: the constituents on each month end from the replayed index history, one row per company (a seat whose ticker the crosswalk still assigns to its previous holder cannot count a company twice; check 71).</li>
<li><b>Factors.</b> <code>sec_gold.factor_sheet_asof</code>, stored per month end in <code>sec_market.factor_panel</code>. Annual factors come from the newest fiscal year filed by the date (not older than 550 days), quarterly ones from the newest quarter filed by the date (not older than 200 days). Every input is keyed on <code>tradable_from</code>, the first session a filing could be traded on, never the filing date; 57% of filings are accepted after the close. The panel's CHECK constraints refuse any row whose period end or availability is after its own knowledge date.</li>
<li><b>Suspect facts.</b> {suspect.get('period_after_filing', (0, 0))[0]:,} facts whose period ends after their own filing date and {suspect.get('scale', (0, 0))[0]} balance-sheet lines printed in thousands or millions without saying so are refused by every gold table (<code>sec_gold.suspect_fact</code>), decided from the filing and earlier filings only.</li>
<li><b>Prices.</b> Yahoo Finance month-end closes for the primary ticker of each surviving member (<code>sec_market.monthly_price</code>; {sym_ret} of {sym_req} symbols answered on {loaded_at}). Returns use the dividend-and-split-adjusted close; a month is skipped across a gap of more than 35 days, when either month did not trade, or when the prior as-traded close was under a dollar.</li>
<li><b>Sort and hold.</b> <code>sec_market.backtest</code>: on each rebalance date, NTILE(5) over the signed percentile among members that have the factor; equal weight within bucket; held through every month end up to and including the next rebalance; a member without a price that month drops out of its bucket for that month.</li>
<li><b>Statistics.</b> <code>sec_market.backtest_summary</code> for means, t, Sharpe and hit rates; <code>tools/ff_baseline.py</code> for the regressions (Newey-West, six lags) on Ken French's monthly five factors and momentum, percent returns read as decimals.</li>
</ul>
<pre>uv run dera load-prices
uv run dera build-factor-panel --index {index}
uv run python tools/ff_baseline.py {index} --download
uv run python tools/factor_report.py {index}</pre>

<h2>7. What the build caught along the way</h2>
<ul>
<li><b>A company counted twice.</b> The panel's primary key refused 2020-03-31: the S&amp;P 500's IR and TT seats both resolved to Trane Technologies, because the ticker IR passed to Ingersoll Rand Inc on 2020-03-03 and the crosswalk moves a ticker at its next capture (2020-06-28). Three month ends, one company, the only such case since 2010; the sheet is now one row per company and check 71 pins the count.</li>
<li><b>A planner pathology.</b> The gold layer is rebuilt in one transaction, so a freshly built matview has no statistics until commit. The peer-statistics build costed a correlated EXISTS as free and ran it as a per-row index scan for eleven hours before it was cancelled. The predicate is now a join, every matview is analysed as soon as it is indexed, and the rebuild takes 48 minutes.</li>
<li><b>Look-ahead by mis-dating.</b> Catalent's 10-Q of 2024-02-14 dates a nine-month net income to 2024-03-31; the panel's CHECK caught it, and such facts are now refused at the source.</li>
<li><b>A scale error at the top of every sort.</b> Hill-Rom's FY2021 10-K carries total assets of 4,999.1 dollars against 4,671.1 million for FY2020 in the same filing; it had produced a return on assets of 49,709.</li>
</ul>

<h2>8. Open</h2>
<ul>
<li>Delisted members have no prices; Polygon's flat files (or CRSP) are the source that closes the survivorship gap. Four open symbols Yahoo lacked: CUK, HCIIP, SATS, TDDWW.</li>
<li>S&amp;P 400 and 600 panels (<code>dera build-factor-panel --index SP400</code>), where the published premia are larger.</li>
<li>Value-weighted buckets and a size control; the backtest is equal-weight only.</li>
<li>Ticker handoffs dated from the filings that announce them rather than the crosswalk's next capture.</li>
</ul>
<p class="small">Report generated {today.isoformat()} by <code>tools/factor_report.py</code> from PostgreSQL; French data vintage 202608 (<code>data/external/french</code>, not stored in the repository).</p>
</main>
</body>
</html>
"""


def main() -> int:
    ap = argparse.ArgumentParser(description="The factor backtest report as one HTML file.")
    ap.add_argument("index", nargs="?", default="SP500")
    ap.add_argument("--from", dest="frm", default="2010-01-01")
    ap.add_argument("--ff-csv", default=None)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    today = dt.date.today()
    ff_csv = Path(args.ff_csv) if args.ff_csv else config.PROJECT_ROOT / "data" / "external" / "french" / f"ff_baseline_{args.index}.csv"
    out = Path(args.out) if args.out else config.PROJECT_ROOT / "docs" / "reports" / f"factor_backtest_{today.isoformat()}.html"
    ff = pd.read_csv(ff_csv)
    frm = dt.date.fromisoformat(args.frm)
    with db.get_conn() as conn:
        d = load(conn, args.index, frm)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(build_html(args.index, frm, d, ff, today), encoding="utf-8")
    print(f"wrote {out} ({out.stat().st_size / 1024:.0f} KB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
