-- sql/07_market/030_backtest.sql
--
-- REBALANCE, HOLD, MEASURE. Does a factor sort pay, in this universe,
-- with these prices? The only question the price layer exists to
-- answer, asked the plain way:
--
--   1. On each rebalance date (every month end in the panel, or the
--      quarter ends, or one month end a year), take the panel rows of
--      that date and sort the members that have the factor into
--      p_buckets equal groups by its signed percentile (bucket 1 the
--      lowest expected return, p_buckets the highest).
--   2. Hold each group, equal-weighted, until the next rebalance date.
--      A member's monthly return is sec_market.monthly_return.ret_1m
--      (total return from adj_close); a member with no price that month
--      drops out of the group for that month.
--   3. Report per month: each bucket's return, the long-short spread
--      (top minus bottom) and the equal-weight return of every member
--      with a price, as the benchmark.
--
-- POINT IN TIME. The panel row for a rebalance date holds only what was
-- knowable on that date; a filing whose tradable_from is that date was
-- tradable in that session, so a close-of-day rebalance may use it. The
-- return earned from that close to the next month's close is the
-- following month's ret_1m. Nothing from after the rebalance date
-- chooses a bucket.
--
-- SURVIVORSHIP, SAID AGAIN. Members whose ticker has since been
-- delisted have no prices here (docs/data_sources.md), so every group
-- holds survivors only. The spread between buckets is less exposed than
-- a bucket's level, because both legs lose the same kind of member, but
-- it is not immune: a bucket that collects future failures (low
-- profitability, low quality) loses them from this measurement.
--
-- backtest(index, factor, freq, from, to, buckets)   month by month
-- backtest_summary(...)                              one row per bucket + spread

DROP FUNCTION IF EXISTS sec_market.backtest(TEXT, TEXT, TEXT, DATE, DATE, INTEGER);
CREATE FUNCTION sec_market.backtest(
    p_index    TEXT,
    p_factor   TEXT,                 -- a *_pct column of the panel, or 'composite'
    p_freq     TEXT    DEFAULT 'monthly',   -- 'monthly' | 'quarterly' | 'annual'
    p_from     DATE    DEFAULT NULL,
    p_to       DATE    DEFAULT NULL,
    p_buckets  INTEGER DEFAULT 5
)
RETURNS TABLE (
    rebalance_date  DATE,
    month_end       DATE,
    bucket          INTEGER,
    members         INTEGER,
    priced          INTEGER,
    ret             NUMERIC,
    benchmark_ret   NUMERIC,
    spread          NUMERIC
)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_col TEXT;
BEGIN
    IF p_factor = 'composite' THEN
        v_col := 'composite';
    ELSIF p_factor ~ '^[a-z_]+_pct$' THEN
        v_col := p_factor;
    ELSE
        v_col := p_factor || '_pct';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                   WHERE table_schema = 'sec_market' AND table_name = 'factor_panel' AND column_name = v_col) THEN
        RAISE EXCEPTION 'factor_panel has no column %', v_col;
    END IF;
    IF p_freq NOT IN ('monthly', 'quarterly', 'annual') THEN
        RAISE EXCEPTION 'p_freq must be monthly, quarterly or annual, not %', p_freq;
    END IF;

    RETURN QUERY EXECUTE format($q$
        WITH dates AS (
            -- The rebalance dates: every panel date, the quarter ends, or
            -- one date a year (the first panel date's month).
            SELECT d.asof
            FROM (SELECT DISTINCT fp.asof FROM sec_market.factor_panel fp WHERE fp.index_name = $1) d
            WHERE ($4 IS NULL OR d.asof >= $4) AND ($5 IS NULL OR d.asof <= $5)
              AND ($3 = 'monthly'
                   OR ($3 = 'quarterly' AND EXTRACT(MONTH FROM d.asof) IN (3, 6, 9, 12))
                   OR ($3 = 'annual' AND EXTRACT(MONTH FROM d.asof) =
                         (SELECT EXTRACT(MONTH FROM MIN(fp2.asof)) FROM sec_market.factor_panel fp2
                           WHERE fp2.index_name = $1 AND ($4 IS NULL OR fp2.asof >= $4))))
        ),
        windows AS (
            SELECT d.asof AS rebalance_date,
                   LEAD(d.asof) OVER (ORDER BY d.asof) AS next_rebalance
            FROM dates d
        ),
        -- Each member's bucket on each rebalance date.
        sorted AS (
            SELECT w.rebalance_date, w.next_rebalance, fp.cik,
                   NTILE($6) OVER (PARTITION BY fp.asof ORDER BY fp.%I, fp.cik) AS bucket
            FROM windows w
            JOIN sec_market.factor_panel fp ON fp.index_name = $1 AND fp.asof = w.rebalance_date
            WHERE fp.%I IS NOT NULL
        ),
        -- The holding months: every month end after the rebalance date
        -- up to and including the next rebalance date (or the last
        -- priced month when there is no next one).
        held AS (
            SELECT s.rebalance_date, s.cik, s.bucket, r.month_end, r.ret_1m
            FROM sorted s
            JOIN sec_market.monthly_return r
              ON r.cik = s.cik
             AND r.month_end > s.rebalance_date
             AND r.month_end <= COALESCE(s.next_rebalance, s.rebalance_date + 400)
             AND r.ticker = COALESCE(sec_reference.ticker_at(s.cik, s.rebalance_date), r.ticker)
        ),
        -- Everyone in the panel that month, for the benchmark.
        bench AS (
            SELECT w.rebalance_date, r.month_end, AVG(r.ret_1m) AS benchmark_ret
            FROM windows w
            JOIN sec_market.factor_panel fp ON fp.index_name = $1 AND fp.asof = w.rebalance_date
            JOIN sec_market.monthly_return r
              ON r.cik = fp.cik
             AND r.month_end > w.rebalance_date
             AND r.month_end <= COALESCE(w.next_rebalance, w.rebalance_date + 400)
             AND r.ticker = COALESCE(sec_reference.ticker_at(fp.cik, w.rebalance_date), r.ticker)
            WHERE r.ret_1m IS NOT NULL
            GROUP BY w.rebalance_date, r.month_end
        ),
        per_bucket AS (
            SELECT h.rebalance_date, h.month_end, h.bucket,
                   COUNT(*)::INTEGER AS members,
                   COUNT(h.ret_1m)::INTEGER AS priced,
                   AVG(h.ret_1m) AS ret
            FROM held h
            GROUP BY h.rebalance_date, h.month_end, h.bucket
        ),
        spread AS (
            SELECT pb.rebalance_date, pb.month_end,
                   MAX(pb.ret) FILTER (WHERE pb.bucket = $6) - MAX(pb.ret) FILTER (WHERE pb.bucket = 1) AS spread
            FROM per_bucket pb
            GROUP BY pb.rebalance_date, pb.month_end
        )
        SELECT pb.rebalance_date, pb.month_end, pb.bucket, pb.members, pb.priced,
               ROUND(pb.ret, 6), ROUND(b.benchmark_ret, 6), ROUND(sp.spread, 6)
        FROM per_bucket pb
        LEFT JOIN bench b ON b.rebalance_date = pb.rebalance_date AND b.month_end = pb.month_end
        LEFT JOIN spread sp ON sp.rebalance_date = pb.rebalance_date AND sp.month_end = pb.month_end
        ORDER BY pb.month_end, pb.bucket
    $q$, v_col, v_col)
    USING p_index, p_factor, p_freq, p_from, p_to, p_buckets;
END;
$$;

COMMENT ON FUNCTION sec_market.backtest(TEXT, TEXT, TEXT, DATE, DATE, INTEGER) IS
    'Sort an index''s panel rows into equal buckets by a signed factor percentile on each '
    'rebalance date (monthly, quarterly or annual), hold equal-weighted until the next one, and '
    'return each bucket''s monthly total return, the equal-weight benchmark and the top-minus-bottom spread.';

-- The summary a reader wants first: per bucket, and for the spread, the
-- mean monthly return, its t-statistic, the annualised return and
-- Sharpe ratio, and the share of months the spread was positive.
DROP FUNCTION IF EXISTS sec_market.backtest_summary(TEXT, TEXT, TEXT, DATE, DATE, INTEGER);
CREATE FUNCTION sec_market.backtest_summary(
    p_index    TEXT,
    p_factor   TEXT,
    p_freq     TEXT    DEFAULT 'monthly',
    p_from     DATE    DEFAULT NULL,
    p_to       DATE    DEFAULT NULL,
    p_buckets  INTEGER DEFAULT 5
)
RETURNS TABLE (
    series          TEXT,
    months          INTEGER,
    first_month     DATE,
    last_month      DATE,
    mean_monthly    NUMERIC,
    t_stat          NUMERIC,
    annualised      NUMERIC,
    sharpe          NUMERIC,
    hit_rate        NUMERIC,
    avg_members     NUMERIC
)
LANGUAGE sql STABLE AS $$
    WITH bt AS (
        SELECT * FROM sec_market.backtest(p_index, p_factor, p_freq, p_from, p_to, p_buckets)
    ),
    series AS (
        SELECT 'bucket ' || bucket AS series, month_end, ret AS r, priced::NUMERIC AS n FROM bt
        UNION ALL
        SELECT 'spread (top - bottom)', month_end, spread, NULL FROM bt WHERE bucket = 1
        UNION ALL
        SELECT 'benchmark (equal-weight)', month_end, benchmark_ret, NULL FROM bt WHERE bucket = 1
    )
    SELECT s.series,
           COUNT(s.r)::INTEGER AS months,
           MIN(s.month_end), MAX(s.month_end),
           ROUND(AVG(s.r), 5) AS mean_monthly,
           ROUND((AVG(s.r) / NULLIF(STDDEV_SAMP(s.r), 0) * SQRT(COUNT(s.r)::NUMERIC))::NUMERIC, 2) AS t_stat,
           ROUND((POWER(1 + AVG(s.r), 12) - 1)::NUMERIC, 4) AS annualised,
           ROUND((AVG(s.r) / NULLIF(STDDEV_SAMP(s.r), 0) * SQRT(12::NUMERIC))::NUMERIC, 2) AS sharpe,
           ROUND(AVG(CASE WHEN s.r > 0 THEN 1 ELSE 0 END), 3) AS hit_rate,
           ROUND(AVG(s.n), 1) AS avg_members
    FROM series s
    WHERE s.r IS NOT NULL
    GROUP BY s.series
    ORDER BY CASE WHEN s.series LIKE 'bucket%' THEN 0 WHEN s.series LIKE 'spread%' THEN 1 ELSE 2 END, s.series;
$$;

COMMENT ON FUNCTION sec_market.backtest_summary(TEXT, TEXT, TEXT, DATE, DATE, INTEGER) IS
    'Per bucket, the spread and the benchmark: months, mean monthly return, t-statistic, annualised '
    'return, Sharpe ratio and hit rate from sec_market.backtest.';
