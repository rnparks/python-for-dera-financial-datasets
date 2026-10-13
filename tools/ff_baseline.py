"""Factor spreads against Fama-French five factors and momentum.

For every factor of sec_market.factor_panel (and the composite), at
monthly, quarterly and annual rebalancing: the top-minus-bottom quintile
spread from sec_market.backtest, its raw mean and t-statistic, and its
alpha on FF5 (Mkt-RF, SMB, HML, RMW, CMA) and on FF5 + UMD, with
Newey-West (six lags) t-statistics and the factor loadings. The
equal-weight benchmark (members minus the risk-free rate) is regressed
too, as the sanity check that the returns and the French series line up
(beta near 1, alpha near 0).

The French files are not stored in the repository: --download fetches
F-F_Research_Data_5_Factors_2x3_CSV.zip and F-F_Momentum_Factor_CSV.zip
from Ken French's data library into --ff-dir (data/external/french by
default, gitignored). Percent returns are converted to decimals; the
monthly block of each file runs from its header line to the first blank
line. docs/data_sources.md section 9.

Usage:
  uv run python tools/ff_baseline.py SP500 --download
  uv run python tools/ff_baseline.py SP500 --from 2012-01-01 --freq quarterly
Writes <ff-dir>/ff_baseline_<index>.csv and prints the spread table.
"""
from __future__ import annotations

import argparse
import datetime as dt
import io
import sys
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from dera_pipeline import config, db  # noqa: E402

FRENCH = "https://mba.tuck.dartmouth.edu/pages/faculty/ken.french/ftp/"
FILES = {
    "F-F_Research_Data_5_Factors_2x3.csv": ("F-F_Research_Data_5_Factors_2x3_CSV.zip",
                                            ["Mkt-RF", "SMB", "HML", "RMW", "CMA", "RF"]),
    "F-F_Momentum_Factor.csv": ("F-F_Momentum_Factor_CSV.zip", ["UMD"]),
}
FACTORS = ["composite", "ocf_at", "gp_at", "roa", "roe", "operating_margin",
           "revenue_growth", "roe_q", "roa_q", "sue"]
MODELS = {"FF5": ["Mkt-RF", "SMB", "HML", "RMW", "CMA"],
          "FF5+UMD": ["Mkt-RF", "SMB", "HML", "RMW", "CMA", "UMD"]}


def download(ff_dir: Path) -> None:
    ff_dir.mkdir(parents=True, exist_ok=True)
    for csv_name, (zip_name, _) in FILES.items():
        req = urllib.request.Request(FRENCH + zip_name, headers={"User-Agent": config.sec_user_agent()})
        with urllib.request.urlopen(req, timeout=120) as resp:
            data = resp.read()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            z.extract(csv_name, ff_dir)
        print(f"fetched {zip_name} -> {ff_dir / csv_name}")


def read_french(path: Path, cols: list[str]) -> pd.DataFrame:
    """The monthly block: from the header line that begins with a comma to
    the first blank line; YYYYMM keys; percent to decimal."""
    lines = path.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(","))
    rows = []
    for line in lines[start + 1:]:
        parts = [p.strip() for p in line.split(",")]
        if not line.strip() or len(parts[0]) != 6 or not parts[0].isdigit():
            break
        rows.append([parts[0]] + [float(p) / 100.0 for p in parts[1:]])
    return pd.DataFrame(rows, columns=["ym"] + cols).set_index("ym")


def load_french(ff_dir: Path) -> pd.DataFrame:
    frames = [read_french(ff_dir / name, cols) for name, (_, cols) in FILES.items()]
    return frames[0].join(frames[1:], how="inner")


def backtest(conn, index: str, factor: str, freq: str, frm: dt.date, to: dt.date | None) -> pd.DataFrame:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT rebalance_date, month_end, bucket, members, priced, ret, benchmark_ret, spread "
            "FROM sec_market.backtest(%s, %s, %s, %s, %s, 5)", (index, factor, freq, frm, to))
        rows = cur.fetchall()
    df = pd.DataFrame(rows, columns=["rebalance_date", "month_end", "bucket", "members", "priced",
                                     "ret", "benchmark_ret", "spread"])
    for c in ("ret", "benchmark_ret", "spread"):
        df[c] = df[c].astype(float)
    df["ym"] = pd.to_datetime(df["month_end"]).dt.strftime("%Y%m")
    return df


def newey_west_ols(y: np.ndarray, X: np.ndarray, lags: int = 6):
    """OLS with Newey-West HAC standard errors: coefficients, t, R-squared."""
    n = len(y)
    beta, *_ = np.linalg.lstsq(X, y, rcond=None)
    e = y - X @ beta
    xtx_inv = np.linalg.inv(X.T @ X)
    xe = X * e[:, None]
    s = xe.T @ xe
    for lag in range(1, lags + 1):
        w = 1 - lag / (lags + 1)
        g = xe[lag:].T @ xe[:-lag]
        s += w * (g + g.T)
    se = np.sqrt(np.diag(xtx_inv @ s @ xtx_inv))
    r2 = 1 - e.var() / y.var() if y.var() > 0 else float("nan")
    return beta, beta / se, r2, n


def annualise(m: float) -> float:
    return (1 + m) ** 12 - 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("index", nargs="?", default="SP500")
    ap.add_argument("--from", dest="frm", default="2010-01-01")
    ap.add_argument("--to", default=None)
    ap.add_argument("--freq", default="monthly,quarterly,annual")
    ap.add_argument("--ff-dir", default=str(config.PROJECT_ROOT / "data" / "external" / "french"))
    ap.add_argument("--download", action="store_true", help="fetch the French files first")
    args = ap.parse_args()
    ff_dir = Path(args.ff_dir)
    if args.download:
        download(ff_dir)
    ff = load_french(ff_dir)
    frm = dt.date.fromisoformat(args.frm)
    to = dt.date.fromisoformat(args.to) if args.to else None
    rows = []
    with db.get_conn() as conn:
        for freq in args.freq.split(","):
            for factor in FACTORS:
                bt = backtest(conn, args.index, factor, freq, frm, to)
                b1 = bt[bt.bucket == 1].set_index("ym")
                for name, s in (("spread", b1["spread"]), ("benchmark-RF", b1["benchmark_ret"])):
                    j = pd.DataFrame({"r": s.dropna()}).join(ff, how="inner")
                    if name == "benchmark-RF":
                        j["r"] = j["r"] - j["RF"]
                    if len(j) < 24:
                        continue
                    y = j["r"].to_numpy(float)
                    rec = {"freq": freq, "factor": factor, "series": name, "months": len(j),
                           "raw_mean_m": y.mean(), "raw_t": y.mean() / y.std(ddof=1) * np.sqrt(len(y)),
                           "raw_ann": annualise(y.mean())}
                    for model, cols in MODELS.items():
                        X = np.column_stack([np.ones(len(j))] + [j[c].to_numpy(float) for c in cols])
                        beta, t, r2, _ = newey_west_ols(y, X)
                        rec[f"{model} alpha_m"] = beta[0]
                        rec[f"{model} alpha_ann"] = annualise(beta[0])
                        rec[f"{model} t_alpha"] = t[0]
                        rec[f"{model} r2"] = r2
                        for c, b, tt in zip(cols, beta[1:], t[1:]):
                            rec[f"{model} b_{c}"] = b
                            rec[f"{model} t_{c}"] = tt
                    rows.append(rec)
    out = pd.DataFrame(rows)
    out_path = ff_dir / f"ff_baseline_{args.index}.csv"
    out.to_csv(out_path, index=False)
    pd.set_option("display.width", 250)
    show = ["freq", "factor", "months", "raw_ann", "raw_t", "FF5 alpha_ann", "FF5 t_alpha",
            "FF5+UMD alpha_ann", "FF5+UMD t_alpha", "FF5+UMD r2", "FF5+UMD b_Mkt-RF", "FF5+UMD b_SMB",
            "FF5+UMD b_HML", "FF5+UMD b_RMW", "FF5+UMD b_CMA", "FF5+UMD b_UMD"]
    print(out[out.series == "spread"][show].to_string(index=False, float_format=lambda v: f"{v:7.3f}"))
    print("\nbenchmark (equal-weight members minus RF):")
    print(out[(out.series == "benchmark-RF") & (out.factor == "composite")][show]
          .to_string(index=False, float_format=lambda v: f"{v:7.3f}"))
    print(f"\nwritten {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
