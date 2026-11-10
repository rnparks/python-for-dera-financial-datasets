"""Market-cap audit: every index member on every panel date, checked.

Market capitalisation (and, built on it, enterprise value) is an input to
every cap-weighted leg, size control and valuation ratio, so an error in a
share count or a price is an error everywhere downstream. The errors that
cost the most are the plausible ones: Exxon Mobil absent from every
backtest for want of a price, McDonald's at 2.3 times its size for reading
issued shares as outstanding, Visa at 63-87% of itself for counting one
class of five, Nvidia at a tenth of itself for four months after its 2024
split. Each was found by looking; this module is the looking, made
repeatable.

The audit reads, it never writes the database. Its input is one row per
(knowledge date, company) of the factor panels with the price, the share
count and the market cap the accessors return on that date, and how each
was chosen (``build_detail``), cached as a parquet file because computing
it calls ``sec_market.price_at`` and ``sec_gold.shares_outstanding_at``
some 230,000 times.

The checks are pure functions over that frame (unit-tested in
``tests/test_pure_functions.py``), each returning flagged rows with a
``check`` name, a ``severity`` and a ``detail``.
"""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pandas as pd

from . import config, db

AUDIT_DIR = config.PROJECT_ROOT / "data" / "external" / "audit"
DETAIL_PATH = AUDIT_DIR / "cap_detail.parquet"
WORKERS = 6

DETAIL_COLUMNS = [
    "asof", "cik", "price_ticker", "price_month_end", "close_raw", "split_factor_after",
    "shares", "shares_value_date", "shares_tradable_from", "shares_tag", "shares_method",
    "split_adjustment",
]

# Price and share count separately (not market_cap_at), so a row missing
# one of them still says which, and the share count's provenance is kept.
# The split adjustment is market_cap_at's (sql/07_market/010_monthly_price.sql),
# restated here so each share count is computed once; check_against_accessor
# compares the two on a sample.
DETAIL_SQL = """
SELECT d.asof, d.cik, pr.ticker, pr.month_end, pr.close_raw, mp.split_factor_after,
       sh.shares, sh.value_date, sh.tradable_from, sh.source_tag, sh.method,
       (SELECT COALESCE(EXP(SUM(LN(se.ratio)) FILTER (WHERE se.split_date > sh.tradable_from
                                                         AND se.split_date <= pr.month_end)), 1)
             / COALESCE(EXP(SUM(LN(se.ratio)) FILTER (WHERE se.split_date > pr.month_end
                                                         AND se.split_date <= sh.tradable_from)), 1)
        FROM sec_market.split_event se WHERE se.ticker = pr.ticker) AS split_adjustment
FROM unnest(%(asof)s::date[], %(cik)s::int[]) AS d(asof, cik)
LEFT JOIN LATERAL sec_market.price_at(d.cik, d.asof) pr ON TRUE
LEFT JOIN sec_market.monthly_price mp
       ON mp.cik = d.cik AND mp.ticker = pr.ticker AND mp.month_end = pr.month_end
LEFT JOIN LATERAL (SELECT * FROM sec_gold.shares_outstanding_at(d.cik, d.asof) LIMIT 1) sh ON TRUE
"""


def panel_keys(conn) -> pd.DataFrame:
    """Every (asof, cik) of every stored factor panel, and which indexes
    hold the company that day."""
    with conn.cursor() as cur:
        cur.execute("""
            SELECT asof, cik, string_agg(index_name, ',' ORDER BY index_name) AS indexes
            FROM sec_market.factor_panel GROUP BY asof, cik ORDER BY asof, cik
        """)
        return pd.DataFrame(cur.fetchall(), columns=["asof", "cik", "indexes"])


def _detail_chunk(keys: pd.DataFrame) -> pd.DataFrame:
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute(DETAIL_SQL, {"asof": list(keys["asof"]), "cik": [int(c) for c in keys["cik"]]})
        return pd.DataFrame(cur.fetchall(), columns=DETAIL_COLUMNS)


def build_detail(path: Path = DETAIL_PATH, rebuild: bool = False, log=print) -> pd.DataFrame:
    """The audit's input, computed once and cached. ``rebuild`` recomputes
    it, which is required after any change to the share ladder or the
    price table: the cache does not know they changed."""
    if path.exists() and not rebuild:
        return pd.read_parquet(path)
    with db.get_conn() as conn:
        keys = panel_keys(conn)
    log(f"audit input: {len(keys):,} company-dates to compute")
    chunks = [keys.iloc[i::WORKERS] for i in range(WORKERS)]
    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        parts = list(ex.map(_detail_chunk, [c for c in chunks if len(c)]))
    out = pd.concat(parts, ignore_index=True)
    out = keys.merge(out, on=["asof", "cik"], how="left")
    for c in ("close_raw", "split_factor_after", "shares", "split_adjustment"):
        out[c] = out[c].astype(float)
    out["market_cap"] = out["close_raw"] * out["shares"] * out["split_adjustment"]
    path.parent.mkdir(parents=True, exist_ok=True)
    out.to_parquet(path, index=False)
    log(f"audit input cached at {path}: {out['market_cap'].notna().sum():,} of {len(out):,} with a market cap")
    return out


def check_against_accessor(detail: pd.DataFrame, n: int = 300, seed: int = 0) -> pd.DataFrame:
    """The audit's market cap against sec_market.market_cap_at on a random
    sample: the audit restates the accessor's split adjustment, and this
    keeps the two from drifting apart. Returns the rows that differ."""
    sample = detail[detail["market_cap"].notna()].sample(min(n, int(detail["market_cap"].notna().sum())), random_state=seed)
    with db.get_conn() as conn, conn.cursor() as cur:
        cur.execute("""
            SELECT d.asof, d.cik, m.market_cap
            FROM unnest(%(asof)s::date[], %(cik)s::int[]) AS d(asof, cik)
            LEFT JOIN LATERAL sec_market.market_cap_at(d.cik, d.asof) m ON TRUE
        """, {"asof": list(sample["asof"]), "cik": [int(c) for c in sample["cik"]]})
        acc = pd.DataFrame(cur.fetchall(), columns=["asof", "cik", "accessor_cap"])
    acc["accessor_cap"] = acc["accessor_cap"].astype(float)
    m = sample.merge(acc, on=["asof", "cik"])
    return m[(m["market_cap"] / m["accessor_cap"] - 1).abs() > 1e-9]


# ----------------------------------------------------------------------
# The checks: pure functions over the audit input
# ----------------------------------------------------------------------

def _flags(rows: pd.DataFrame, check: str, severity: str, detail) -> pd.DataFrame:
    out = rows.copy()
    out["check"] = check
    out["severity"] = severity
    out["detail"] = detail(out) if callable(detail) else detail
    return out


def check_shares_vs_own_average(detail: pd.DataFrame, references: pd.DataFrame,
                                low: float = 0.8, high: float = 1.25) -> pd.DataFrame:
    """Step 4. The chosen share count against the filer's own counts of the
    same period (``references``: cik, shares_value_date, basic_avg,
    implied = net income over basic EPS, cover = the cover-page count). A
    count is flagged only when it is outside [low, high] of EVERY reference
    present, because a filer mis-scales a weighted average as readily as a
    share count, and a REIT's net income carries its minority interest: issued read
    as outstanding (McDonald's 2.3), an unmapped class (Visa 0.7), a scale
    error. A merger inside the period moves an instant count away from the
    period's averages legitimately; the exceptions file says so. The count
    is put on the references' split basis (its split adjustment is about
    the price, so it is not applied here)."""
    m = detail.merge(references, on=["cik", "shares_value_date"], how="inner")
    cols = [c for c in ("basic_avg", "implied", "cover") if c in m.columns]
    refs = m[cols].where(m[cols] > 0)
    m = m[refs.notna().any(axis=1)]
    refs = refs.loc[m.index]
    ratios = refs.rdiv(m["shares"], axis=0)
    inside = ((ratios >= low) & (ratios <= high)).any(axis=1)
    m = m.assign(ratio_to_avg=ratios["basic_avg"], ratio_to_implied=ratios["implied"],
                 ratio_to_cover=ratios["cover"] if "cover" in ratios else float("nan"))
    bad = m[~inside]
    return _flags(bad, "shares_vs_own_counts", "flag",
                  lambda x: "count / own average = " + x["ratio_to_avg"].round(3).astype(str)
                            + ", / NI over EPS = " + x["ratio_to_implied"].round(3).astype(str)
                            + ", / cover = " + x["ratio_to_cover"].round(3).astype(str))


def check_share_continuity(detail: pd.DataFrame, low: float = 0.8, high: float = 1.25) -> pd.DataFrame:
    """Step 5. A company's share count, put on one split basis (the as-filed
    count times its split adjustment times the price's split factor after),
    from one panel month to the next on the same listing. A move outside
    [low, high] in a month is a merger, a spin-off, or an error: W. R.
    Berkley's thousand-fold 2012 counts, a split the dated history lacks."""
    d = detail[detail["market_cap"].notna()].copy()
    d["shares_today_basis"] = d["shares"] * d["split_adjustment"] * d["split_factor_after"]
    d = d.sort_values(["cik", "asof"])
    prev = d.groupby("cik")[["asof", "price_ticker", "shares_today_basis"]].shift(1)
    d["prev_asof"] = prev["asof"]
    d["move"] = d["shares_today_basis"] / prev["shares_today_basis"]
    same = (prev["price_ticker"] == d["price_ticker"]) & \
           ((pd.to_datetime(d["asof"]) - pd.to_datetime(prev["asof"])).dt.days <= 35)
    bad = d[same & ((d["move"] < low) | (d["move"] > high))]
    return _flags(bad, "share_continuity", "flag",
                  lambda x: "shares moved x" + x["move"].round(3).astype(str) + " since " + x["prev_asof"].astype(str))


def check_returns(returns: pd.DataFrame, high: float = 1.0, low: float = -0.5) -> pd.DataFrame:
    """Step 6. A monthly total return above +100% or below -50% (``returns``:
    cik, ticker, month_end, ret_1m). Real events exist (a takeover bid, a
    bankruptcy); so do vendor artefacts (a pre-listing series, a split the
    adjusted close missed). Each is looked at once and explained."""
    bad = returns[(returns["ret_1m"] > high) | (returns["ret_1m"] < low)]
    return _flags(bad, "extreme_return", "flag",
                  lambda x: "monthly return " + (100 * x["ret_1m"]).round(1).astype(str) + "%")


def check_concentration(detail: pd.DataFrame, max_share: float = 0.15) -> pd.DataFrame:
    """Step 7. No company holds more than ``max_share`` of an index's total
    market cap on a date (the real maximum in the S&P 500 is 6-8%). Above it
    is a reject: one such cap decides every cap-weighted figure it touches."""
    rows = []
    for idx in ("SP500", "SP400", "SP600", "SP1500"):
        d = detail[detail["indexes"].str.contains(idx, regex=False) & detail["market_cap"].notna()].copy()
        d["index_share"] = d["market_cap"] / d.groupby("asof")["market_cap"].transform("sum")
        d["index_name"] = idx
        rows.append(d[d["index_share"] > max_share])
    bad = pd.concat(rows, ignore_index=True) if rows else detail.iloc[:0]
    return _flags(bad, "concentration", "reject",
                  lambda x: x["index_name"] + " share " + (100 * x["index_share"]).round(1).astype(str) + "%")


# Three references from the filer's own statements, because any one can
# be mis-scaled or mis-defined by the filer (McDonald's tags some weighted
# averages in millions; a REIT's net income includes its operating
# partnership's minority interest, so net income over EPS overstates its
# shares by a quarter): the basic weighted average of the period ending at
# the count's date, net income over basic EPS of that period, and the
# newest cover-page count (sec_reference.cover_share_count) knowable on the
# first date the count was used, dated within 200 days after it.
REFERENCE_SQL = """
SELECT d.cik, d.vd AS shares_value_date, w.value AS basic_avg, e.implied, c.shares AS cover
FROM unnest(%(cik)s::int[], %(vd)s::date[], %(asof)s::date[]) AS d(cik, vd, asof)
-- A filing inside a sec_reference.share_unit window (Berkshire to 2017)
-- states its averages and EPS per unit of the whole company,
-- undimensioned or tagged with the unit's class member; the references
-- are converted as the share ladder converts the counts.
LEFT JOIN LATERAL (
    SELECT n.value * COALESCE(u.shares_per_unit, 1) AS value
    FROM sec_silver.num_silver n
    LEFT JOIN sec_reference.share_unit u
      ON u.cik = n.cik AND n.tradable_from >= u.filed_from
     AND (u.filed_to IS NULL OR n.tradable_from < u.filed_to)
    WHERE n.cik = d.cik AND n.coreg IS NULL AND n.uom = 'shares'
      AND (n.segments IS NULL OR n.segments = 'ClassOfStock=' || u.unit_member || ';')
      AND n.tag = 'WeightedAverageNumberOfSharesOutstandingBasic' AND n.value > 0
      AND n.value_date BETWEEN d.vd - 100 AND d.vd
      AND n.tradable_from <= d.asof
      AND (n.superseded_tradable > d.asof OR n.superseded_tradable IS NULL)
    ORDER BY n.value_date DESC, n.qtrs ASC LIMIT 1) w ON TRUE
LEFT JOIN LATERAL (
    SELECT ABS(ni.value / eps.value) * COALESCE(u.shares_per_unit, 1) AS implied
    FROM sec_silver.num_silver ni
    LEFT JOIN sec_reference.share_unit u
      ON u.cik = ni.cik AND ni.tradable_from >= u.filed_from
     AND (u.filed_to IS NULL OR ni.tradable_from < u.filed_to)
    JOIN sec_silver.num_silver eps
      ON eps.adsh = ni.adsh AND eps.cik = ni.cik AND eps.value_date = ni.value_date AND eps.qtrs = ni.qtrs
     AND eps.tag = 'EarningsPerShareBasic' AND eps.coreg IS NULL
     AND (eps.segments IS NULL OR eps.segments = 'ClassOfStock=' || u.unit_member || ';')
     AND ABS(eps.value) >= 0.05
    WHERE ni.cik = d.cik AND ni.tag = 'NetIncomeLoss' AND ni.segments IS NULL AND ni.coreg IS NULL
      AND ni.value <> 0 AND ni.value_date BETWEEN d.vd - 100 AND d.vd
      AND ni.tradable_from <= d.asof
      AND (ni.superseded_tradable > d.asof OR ni.superseded_tradable IS NULL)
    ORDER BY ni.value_date DESC, ni.qtrs DESC LIMIT 1) e ON TRUE
LEFT JOIN LATERAL (
    SELECT cv.shares FROM sec_reference.cover_share_count cv
    WHERE cv.cik = d.cik AND cv.tradable_from <= d.asof
      AND cv.cover_date BETWEEN d.vd AND d.vd + 200
    ORDER BY cv.cover_date LIMIT 1) c ON TRUE
"""


def share_references(detail: pd.DataFrame) -> pd.DataFrame:
    """The filer's own basic weighted-average count for the period ending
    at each share count's date, as knowable on the first panel date that
    count was used (the reference must not see a later restatement)."""
    keys = (detail[detail["shares"].notna()]
            .groupby(["cik", "shares_value_date"], as_index=False)["asof"].min())
    chunks = [keys.iloc[i::WORKERS] for i in range(WORKERS)]

    def run(k: pd.DataFrame) -> pd.DataFrame:
        with db.get_conn() as conn, conn.cursor() as cur:
            cur.execute(REFERENCE_SQL, {"cik": [int(c) for c in k["cik"]],
                                        "vd": list(k["shares_value_date"]), "asof": list(k["asof"])})
            return pd.DataFrame(cur.fetchall(), columns=["cik", "shares_value_date", "basic_avg", "implied", "cover"])

    with ThreadPoolExecutor(max_workers=WORKERS) as ex:
        parts = list(ex.map(run, [c for c in chunks if len(c)]))
    out = pd.concat(parts, ignore_index=True)
    out["basic_avg"] = out["basic_avg"].astype(float)
    out["implied"] = out["implied"].astype(float)
    out["cover"] = out["cover"].astype(float)
    return out
