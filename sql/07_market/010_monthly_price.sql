-- sql/07_market/010_monthly_price.sql
--
-- MONTH-END PRICES FOR INDEX MEMBERS: the smallest price layer that
-- makes the fundamentals testable. One row per company, ticker and
-- month end, from Yahoo Finance through the yfinance package, loaded by
-- `dera load-prices` (dera_pipeline/prices.py). Not SEC data: its own
-- schema, so nothing in sec_gold depends on it and a reader always
-- knows which numbers came from a filing and which from a vendor.
--
-- THREE CLOSES, BECAUSE A SPLIT REWRITES HISTORY.
--   close_split_adj  Yahoo's "Close": the month's last close restated for
--                    every split that came LATER (Apple's July 2020 close
--                    reads 106.26, not the 425.04 it traded at).
--   adj_close        Yahoo's "Adj Close": split- and dividend-adjusted,
--                    a total-return index; ratios of it are total returns.
--   close_raw        as traded: close_split_adj times the product of the
--                    split ratios after that month (425.04). This is the
--                    one to multiply filed share counts by: the cover page
--                    counts the shares that existed then.
-- The reconstruction is a pure function (prices.reconstruct_raw_close,
-- tested) over the split ratios Yahoo reports in the month they fell.
--
-- POINT IN TIME. A month-end close is knowable after that session; the
-- accessors below take the newest month end STRICTLY BEFORE the
-- knowledge date, never the date's own close. Shares come from
-- sec_gold.shares_outstanding_at, the cover-page count knowable on the
-- date. Nothing about a later month, split or delisting enters a value.
--
-- WHAT IS NOT HERE, SAID PLAINLY. Yahoo returns nothing for a delisted
-- ticker and re-keys a reused one to its current holder, so only OPEN
-- listings of companies that were ever S&P 1500 members are loaded,
-- each attributed to the company that holds the ticker today. A member
-- that was acquired, went private or failed has no row: the loader
-- prints that count and docs/data_sources.md carries it. A backtest on
-- this table sees survivors only; that is a bias, and it is the reason
-- the roadmap's paid source (Polygon flat files) is still the one that
-- closes it.
--
-- ONE EXCEPTION FOLLOWS THE TICKER, NOT THE CIK. A share-for-share
-- successor issuer (a holding-company reorganisation or redomicile that
-- converted every share into one share of a new registrant under the
-- same ticker; data/reference/successor_issuers.csv, each row citing its
-- 8-K12B) did not change the security, so the series before the
-- reorganisation is stored under the predecessor too, up to its handoff
-- (prices.succession_windows). Exxon Mobil (34088) had no row in any
-- month until 2026-11-09: XOM's open listing belonged to ExxonMobil
-- Holdings (2115436), which has no filing in DERA yet and so no security
-- row. Check 80.
--
-- One month's rows for 1,700 companies are about 1,700 rows; the whole
-- table since 2008 is well under 100 MB.

CREATE SCHEMA IF NOT EXISTS sec_market;

CREATE TABLE IF NOT EXISTS sec_market.monthly_price (
    cik                 INTEGER     NOT NULL,
    ticker              TEXT        NOT NULL,   -- the spine's listing ticker
    yahoo_symbol        TEXT        NOT NULL,   -- what was asked of Yahoo
    month_end           DATE        NOT NULL,   -- the month's last NYSE session
    close_split_adj     NUMERIC     NOT NULL,
    adj_close           NUMERIC     NOT NULL,
    close_raw           NUMERIC     NOT NULL,
    split_factor_after  NUMERIC     NOT NULL DEFAULT 1,
    volume              BIGINT,
    source              TEXT        NOT NULL DEFAULT 'yahoo',
    fetched_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (cik, ticker, month_end),
    CHECK (close_split_adj > 0 AND adj_close > 0 AND close_raw > 0 AND split_factor_after > 0),
    CHECK (month_end = (date_trunc('month', month_end) + INTERVAL '1 month - 1 day')::DATE
           OR EXTRACT(DAY FROM month_end) >= 20)   -- a month's last session, never a mid-month date
);
CREATE INDEX IF NOT EXISTS idx_monthly_price_month ON sec_market.monthly_price (month_end);

COMMENT ON TABLE sec_market.monthly_price IS
    'Month-end closes for every open listing of a company that was ever an S&P 1500 member, '
    'from Yahoo Finance (dera load-prices). close_split_adj is Yahoo''s split-restated close, '
    'adj_close its total-return index, close_raw the reconstructed as-traded close. Delisted '
    'tickers have no rows (survivorship: see docs/data_sources.md).';

-- Every load, so a reader can tell when the vendor was last asked and
-- how much of the universe answered.
-- SPLITS, DATED TO THE DAY. A share count is on the split basis of the
-- day it was filed (a filing after a split restates its counts: Nvidia's
-- FY2025 10-K carries 2024-01-31 at 24,643M, the FY2024 10-K at 2,464M);
-- a month-end close is on the basis of every split up to that month end.
-- Multiplying the two across a split is wrong by the split ratio: Apple
-- read $553B in September 2020 (4-for-1 on 2020-08-31), Nvidia $288-304B
-- from July to October 2024 (10-for-1 on 2024-06-10; its 10-Qs carry no
-- instant count, so the pre-split 10-K count stood for a year). Yahoo's
-- monthly bars say which month a split fell in, not the day, and a split
-- and a filing in the same month are then ambiguous; so the day comes
-- from Yahoo's split history (yfinance Ticker.splits: the first session
-- on the new basis), fetched by `dera load-prices` for every symbol whose
-- monthly bars carry a split, and market_cap_at applies it. Check 82.
CREATE TABLE IF NOT EXISTS sec_market.split_event (
    ticker          TEXT        NOT NULL,   -- the spine's listing ticker, as in monthly_price
    yahoo_symbol    TEXT        NOT NULL,
    split_date      DATE        NOT NULL,   -- first session on the new basis
    ratio           NUMERIC     NOT NULL,   -- new shares per old (0.1 for a 1-for-10 reverse split)
    source          TEXT        NOT NULL DEFAULT 'yahoo',
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (ticker, split_date),
    CHECK (ratio > 0 AND ratio <> 1)
);

COMMENT ON TABLE sec_market.split_event IS
    'Stock splits to the day (Yahoo split history), for every listing whose monthly bars carry one; '
    'market_cap_at puts a share count and a price on one split basis with them.';

CREATE TABLE IF NOT EXISTS sec_market.price_load (
    loaded_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    source              TEXT        NOT NULL,
    symbols_requested   INTEGER     NOT NULL,
    symbols_returned    INTEGER     NOT NULL,
    rows_written        INTEGER     NOT NULL,
    first_month         DATE,
    last_month          DATE,
    members_without_listing INTEGER,
    note                TEXT
);

-- Monthly total return per listing: this month's adj_close over last
-- month's, when last month is the month before (no gap), both months
-- traded (volume above zero) and last month's as-traded close at least
-- a dollar. Below a dollar Yahoo's series for a thinly traded line can
-- carry a 0.0037 that becomes a 10,000-fold "return" the next month;
-- a real penny-stock month is lost with it, which is the cheaper error.
CREATE OR REPLACE VIEW sec_market.monthly_return AS
SELECT p.cik, p.ticker, p.month_end, p.close_raw, p.adj_close,
       CASE WHEN prev.month_end >= p.month_end - 35
             AND prev.close_raw >= 1
             AND COALESCE(prev.volume, 0) > 0 AND COALESCE(p.volume, 0) > 0
            THEN p.adj_close / prev.adj_close - 1 END AS ret_1m,
       prev.month_end AS prev_month_end
FROM sec_market.monthly_price p
LEFT JOIN LATERAL (
    SELECT q.month_end, q.adj_close, q.close_raw, q.volume
    FROM sec_market.monthly_price q
    WHERE q.cik = p.cik AND q.ticker = p.ticker AND q.month_end < p.month_end
    ORDER BY q.month_end DESC LIMIT 1
) prev ON TRUE;

COMMENT ON VIEW sec_market.monthly_return IS
    'One-month total return per listing from adj_close; NULL across a gap of more than 35 days, '
    'when either month did not trade, or when the prior close was under a dollar.';

-- The newest month-end close knowable on a date: strictly before it,
-- and within 45 days so a stale series yields nothing. The ticker the
-- spine says the company carried on the date is preferred when it has
-- a price; another listing of the same company otherwise.
DROP FUNCTION IF EXISTS sec_market.price_at(INTEGER, DATE);
CREATE FUNCTION sec_market.price_at(p_cik INTEGER, p_asof DATE)
RETURNS TABLE (ticker TEXT, month_end DATE, close_raw NUMERIC, adj_close NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT p.ticker, p.month_end, p.close_raw, p.adj_close
    FROM sec_market.monthly_price p
    WHERE p.cik = p_cik
      AND p.month_end < p_asof
      AND p.month_end >= p_asof - 45
    ORDER BY (p.ticker = sec_reference.ticker_at(p_cik, p_asof)) DESC, p.month_end DESC, p.ticker
    LIMIT 1;
$$;

COMMENT ON FUNCTION sec_market.price_at(INTEGER, DATE) IS
    'The newest month-end close strictly before p_asof (within 45 days), as traded and as a '
    'total-return index; the ticker the spine assigns on the date preferred.';

-- Market capitalisation as knowable on a date: the as-traded close of
-- the newest month end before it, times the share count knowable on it
-- put on that close's split basis: every split dated after the day the
-- count was filed and on or before the month end multiplies it, every
-- split dated after the month end and on or before the filing divides it
-- (a count filed after the price was struck, across a split between
-- them). One price for every class (the primary ticker's), so a
-- dual-class issuer with a differently priced second class is
-- approximate; the per-class table (sec_gold.share_class_shares) is the
-- place to refine it.
DROP FUNCTION IF EXISTS sec_market.market_cap_at(INTEGER, DATE);
CREATE FUNCTION sec_market.market_cap_at(p_cik INTEGER, p_asof DATE)
RETURNS TABLE (ticker TEXT, month_end DATE, close_raw NUMERIC,
               shares NUMERIC, shares_value_date DATE, shares_tradable_from DATE,
               split_adjustment NUMERIC, market_cap NUMERIC)
LANGUAGE sql STABLE AS $$
    SELECT pr.ticker, pr.month_end, pr.close_raw,
           sh.shares, sh.value_date, sh.tradable_from,
           sa.adj AS split_adjustment,
           pr.close_raw * sh.shares * sa.adj AS market_cap
    FROM sec_market.price_at(p_cik, p_asof) pr
    CROSS JOIN LATERAL (
        SELECT s.shares, s.value_date, s.tradable_from
        FROM sec_gold.shares_outstanding_at(p_cik, p_asof) s
        LIMIT 1
    ) sh
    CROSS JOIN LATERAL (
        SELECT COALESCE(EXP(SUM(LN(se.ratio)) FILTER (WHERE se.split_date > sh.tradable_from
                                                         AND se.split_date <= pr.month_end)), 1)
             / COALESCE(EXP(SUM(LN(se.ratio)) FILTER (WHERE se.split_date > pr.month_end
                                                         AND se.split_date <= sh.tradable_from)), 1) AS adj
        FROM sec_market.split_event se
        WHERE se.ticker = pr.ticker
    ) sa
    WHERE sh.shares > 0;
$$;

COMMENT ON FUNCTION sec_market.market_cap_at(INTEGER, DATE) IS
    'As-traded month-end close before p_asof times the shares knowable on p_asof, put on the '
    'close''s split basis (split_event dated after the count was filed); nothing when either is missing.';
