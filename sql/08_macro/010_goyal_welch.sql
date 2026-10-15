-- sql/08_macro/010_goyal_welch.sql
--
-- THE GOYAL-WELCH PREDICTORS: the aggregate-market variables of Welch and
-- Goyal (2008, RFS 21(4)) and Goyal, Welch and Zafirov (2024, RFS 37(11)),
-- as Amit Goyal publishes them, loaded by `dera load-macro`
-- (dera_pipeline/macro.py). Not SEC data and not about any one company,
-- so a schema of its own: nothing in sec_gold or sec_market depends on it.
--
-- STORED AS PUBLISHED. gw_observation holds every non-empty cell of the
-- combined workbook's Monthly, Quarterly and Annual sheets (the GW 2008
-- and GWZ 2024 data in one file), plus the two quarterly series only the
-- 2008 workbook carries (D3, E3). The loader refuses a vintage in which
-- the two workbooks disagree on any cell they share; on 2026-10-15 they
-- agreed on every one.
--
-- NEVER RANKED ACROSS STOCKS. A macro variable has one value per month
-- that every stock shares: there is no cross-section to rank it in. No
-- table or function here has a company key, and gkx_state returns one row
-- per month, so the state can only be joined to a stock panel by date. A
-- model of the Gu, Kelly and Xiu (2020) kind ranks the characteristics
-- cross-sectionally into [-1, 1] and multiplies them by the RAW macro
-- state, z = (1, x_t) (x) c_i,t (their eq. 21); the time-series
-- normalisation below is the only transformation a macro value gets.
--
-- POINT IN TIME, BY AN ALLOWLIST. The workbook is dated by period, not by
-- when a value could be known, and some of its values could not be known
-- at all on their own date. gw_variable (from the tracked, cited
-- data/reference/goyal_welch_variables.csv) gives each variable a timing
-- class, and only three classes ever reach an accessor:
--   market       a closing price, yield or return: usable from the first
--                day of the next month, strictly after the period's last
--                session, the rule sec_market.price_at applies to prices.
--   release_lag  published after the period: usable lag_months later
--                (inflation: one more month, after BLS's release).
--   quarter_end  12-month dividends and earnings. The monthly sheet fills
--                the months between quarter ends on a straight line to the
--                NEXT quarter end (all 136 such months of each, 2009-2025,
--                measured 2026-10-15), so a monthly value depends on a
--                figure not yet known. Only quarter-end values are read;
--                earnings lag three months for the filings that make them.
-- Three classes never reach an accessor: interpolated (d/p, e/p, d/y,
-- d/e, built from those interpolated months; gkx_state recomputes the
-- ratios from usable parts), full_sample (estimated over the whole sample,
-- look-ahead by construction, per the workbook's own ReadMe) and
-- unverified (no cited timing rule yet). A variable whose timing is
-- unknown produces nothing, not a plausible number.
--
-- A value stays current only until its successor was due (valid_until):
-- the workbook is updated about once a year, and a December value read in
-- September is nine months stale, so the accessors return nothing rather
-- than carry it forward.
--
-- One vintage, the newest: 77,552 rows on 2026-10-15, 11 MB with the index.

CREATE SCHEMA IF NOT EXISTS macro;

CREATE TABLE IF NOT EXISTS macro.gw_variable (
    variable          TEXT    PRIMARY KEY,   -- the workbook's column name: 'd/p', 'b/m', 'AAA'
    description       TEXT    NOT NULL,
    native_frequency  CHAR(1) NOT NULL CHECK (native_frequency IN ('M', 'Q', 'A', 'S')),
    timing            TEXT    NOT NULL CHECK (timing IN (
                          'market', 'release_lag', 'quarter_end',
                          'interpolated', 'full_sample', 'unverified')),
    lag_months        INTEGER,
    source_note       TEXT    NOT NULL CHECK (length(btrim(source_note)) > 0),
    -- A lag exactly when the variable is usable at all, and of the kind
    -- its class implies: a market value is usable the month after, a
    -- released one later than that.
    CHECK ((timing IN ('market', 'release_lag', 'quarter_end')) = (lag_months IS NOT NULL)),
    CHECK (lag_months IS NULL OR lag_months BETWEEN 0 AND 12),
    CHECK (timing <> 'market' OR lag_months = 0),
    CHECK (timing <> 'release_lag' OR lag_months >= 1),
    -- A usable variable is read from its native sheet, which must exist.
    CHECK (timing NOT IN ('market', 'release_lag', 'quarter_end') OR native_frequency IN ('M', 'Q', 'A'))
);

COMMENT ON TABLE macro.gw_variable IS
    'One row per Goyal-Welch variable: what it is, its native frequency and the timing class that decides '
    'whether and from when a point-in-time accessor may read it. Loaded from '
    'data/reference/goyal_welch_variables.csv; every row cites its source.';

CREATE TABLE IF NOT EXISTS macro.gw_observation (
    variable    TEXT             NOT NULL REFERENCES macro.gw_variable (variable),
    frequency   CHAR(1)          NOT NULL CHECK (frequency IN ('M', 'Q', 'A')),  -- the sheet
    period_end  DATE             NOT NULL,   -- last calendar day of the month, quarter or year
    value       DOUBLE PRECISION NOT NULL CHECK (value NOT IN ('NaN', 'Infinity', '-Infinity')),
    source      TEXT             NOT NULL CHECK (source IN ('gwz_combined', 'gw2008')),
    PRIMARY KEY (variable, frequency, period_end),
    CHECK (period_end = (date_trunc('month', period_end) + INTERVAL '1 month - 1 day')::DATE),
    CHECK (frequency <> 'Q' OR EXTRACT(MONTH FROM period_end) IN (3, 6, 9, 12)),
    CHECK (frequency <> 'A' OR EXTRACT(MONTH FROM period_end) = 12)
);

COMMENT ON TABLE macro.gw_observation IS
    'Every non-empty cell of the Goyal-Welch workbooks as published (float8, the workbook''s own binary '
    'values), keyed by variable, sheet and period end. Dated by period, not availability: read it '
    'through macro.gw_usable, gw_asof or gkx_state for anything point in time.';

-- Every load: which file, which vintage, and how much of the stored
-- history it moved. A new vintage restating old months is reported, not
-- silently absorbed.
CREATE TABLE IF NOT EXISTS macro.gw_load (
    loaded_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    source             TEXT        NOT NULL,
    url                TEXT,
    sha256             TEXT        NOT NULL,
    workbook_modified  TIMESTAMPTZ,          -- the workbook's own last-modified stamp: the vintage
    rows_in_file       INTEGER     NOT NULL,
    rows_added         INTEGER     NOT NULL,
    rows_changed       INTEGER     NOT NULL,
    rows_removed       INTEGER     NOT NULL,
    first_period       DATE,
    last_period        DATE
);

-- The first day a value for the period ending p_period_end may be used:
-- the first of the month after the period, plus the lag. Always a first
-- of the month, so every knowledge date in a calendar month sees the same
-- values, and a month-end rebalance never sees its own month's close.
CREATE OR REPLACE FUNCTION macro.gw_usable_from(p_period_end DATE, p_lag_months INTEGER)
RETURNS DATE
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT (date_trunc('month', p_period_end) + make_interval(months => 1 + p_lag_months))::DATE;
$$;

COMMENT ON FUNCTION macro.gw_usable_from(DATE, INTEGER) IS
    'First day a Goyal-Welch value for the period may be used: the first of the month after the period plus the lag.';

-- The observations an accessor may read, with the interval in which each
-- is the current value: from usable_from until its successor was due
-- (one month on, three for a quarter-end or quarterly series, twelve for
-- an annual one). Only the variable's native sheet; for a quarter_end
-- variable only quarter-end periods.
CREATE OR REPLACE VIEW macro.gw_usable AS
SELECT o.variable, o.frequency, o.period_end, o.value, v.timing, v.lag_months,
       macro.gw_usable_from(o.period_end, v.lag_months) AS usable_from,
       (macro.gw_usable_from(o.period_end, v.lag_months)
        + make_interval(months => CASE WHEN v.timing = 'quarter_end' OR o.frequency = 'Q' THEN 3
                                       WHEN o.frequency = 'A' THEN 12
                                       ELSE 1 END))::DATE AS valid_until
FROM macro.gw_observation o
JOIN macro.gw_variable v ON v.variable = o.variable AND v.native_frequency = o.frequency
WHERE v.timing IN ('market', 'release_lag', 'quarter_end')
  AND (v.timing <> 'quarter_end' OR EXTRACT(MONTH FROM o.period_end) IN (3, 6, 9, 12));

COMMENT ON VIEW macro.gw_usable IS
    'The Goyal-Welch observations a point-in-time reader may use, each current from usable_from until '
    'valid_until (when its successor was due). Interpolated, full-sample and unverified variables never appear.';

-- Every usable variable's current value on a knowledge date: one row per
-- variable, nothing for a variable whose newest value is stale or not
-- yet usable. No default date.
DROP FUNCTION IF EXISTS macro.gw_asof(DATE);
CREATE FUNCTION macro.gw_asof(p_asof DATE)
RETURNS TABLE (variable TEXT, frequency CHAR(1), period_end DATE, value DOUBLE PRECISION,
               usable_from DATE, valid_until DATE)
LANGUAGE sql STABLE STRICT AS $$
    SELECT u.variable, u.frequency, u.period_end, u.value, u.usable_from, u.valid_until
    FROM macro.gw_usable u
    WHERE u.usable_from <= p_asof AND p_asof < u.valid_until
    ORDER BY u.variable;
$$;

COMMENT ON FUNCTION macro.gw_asof(DATE) IS
    'Each usable Goyal-Welch variable''s current value on a knowledge date, with the period it describes '
    'and when it became usable; nothing for a stale or not-yet-usable variable.';

-- THE EIGHT MACRO PREDICTORS OF GU, KELLY AND XIU (2020), "following the
-- variable definitions detailed in Welch and Goyal (2008)": dp and ep are
-- log ratios (log dividends or earnings less log price), bm the Dow's
-- book-to-market, ntis net equity expansion, tbl the bill rate, tms the
-- term spread (lty - tbl), dfy the default spread (BAA - AAA), svar the
-- month's sum of squared daily returns.
--
-- One row per calendar month (the state every knowledge date in that
-- month sees), raw and normalised. dp and ep combine the newest usable
-- quarter-end dividends or earnings with the newest usable price, so a
-- ratio is never built from a number the market did not have yet.
--
-- The normalisation is time-series and backward-looking only: each
-- month's z-score is against the mean and sample standard deviation of
-- that variable's own monthly states up to and including that month, over
-- p_window_months (NULL: every month since the series began), and NULL
-- until p_min_months states exist. Adding later months cannot move an
-- earlier row (check 78). The whole history feeds the window whatever
-- p_from is; p_from and p_to only choose the rows returned.
DROP FUNCTION IF EXISTS macro.gkx_state(DATE, DATE, INTEGER, INTEGER);
CREATE FUNCTION macro.gkx_state(
    p_from           DATE,
    p_to             DATE,
    p_window_months  INTEGER DEFAULT NULL,
    p_min_months     INTEGER DEFAULT 120)
RETURNS TABLE (
    month DATE,
    dp DOUBLE PRECISION, ep DOUBLE PRECISION, bm DOUBLE PRECISION, ntis DOUBLE PRECISION,
    tbl DOUBLE PRECISION, tms DOUBLE PRECISION, dfy DOUBLE PRECISION, svar DOUBLE PRECISION,
    dp_z DOUBLE PRECISION, ep_z DOUBLE PRECISION, bm_z DOUBLE PRECISION, ntis_z DOUBLE PRECISION,
    tbl_z DOUBLE PRECISION, tms_z DOUBLE PRECISION, dfy_z DOUBLE PRECISION, svar_z DOUBLE PRECISION,
    price_period DATE, d12_period DATE, e12_period DATE, market_period DATE)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    w INTEGER := COALESCE(p_window_months, 1000000) - 1;
BEGIN
    IF p_from IS NULL OR p_to IS NULL THEN
        RAISE EXCEPTION 'gkx_state needs p_from and p_to; there is no default date range';
    END IF;
    IF p_window_months IS NOT NULL AND p_window_months < 2 THEN
        RAISE EXCEPTION 'p_window_months must be at least 2 (or NULL for an expanding window)';
    END IF;
    RETURN QUERY
    WITH months AS (
        SELECT gs::DATE AS month
        FROM generate_series(
                 (SELECT MIN(u.usable_from) FROM macro.gw_usable u),
                 date_trunc('month', p_to)::DATE, INTERVAL '1 month') gs
    ),
    -- Each value spread over the months it is current in (one for a
    -- monthly series, three for a quarter-end one), so the months join
    -- on equality: a range join of 1,860 months against the view is a
    -- nested loop that took minutes.
    cur AS (
        SELECT gs::DATE AS month, u.variable, u.value, u.period_end
        FROM macro.gw_usable u
        CROSS JOIN LATERAL generate_series(u.usable_from, u.valid_until - 1, INTERVAL '1 month') gs
        WHERE u.variable IN ('price', 'd12', 'e12', 'b/m', 'ntis', 'tbl', 'tms', 'dfy', 'svar')
    ),
    wide AS (
        SELECT m.month,
               MAX(c.value)      FILTER (WHERE c.variable = 'price') AS price,
               MAX(c.value)      FILTER (WHERE c.variable = 'd12')   AS d12,
               MAX(c.value)      FILTER (WHERE c.variable = 'e12')   AS e12,
               MAX(c.value)      FILTER (WHERE c.variable = 'b/m')   AS bm,
               MAX(c.value)      FILTER (WHERE c.variable = 'ntis')  AS ntis,
               MAX(c.value)      FILTER (WHERE c.variable = 'tbl')   AS tbl,
               MAX(c.value)      FILTER (WHERE c.variable = 'tms')   AS tms,
               MAX(c.value)      FILTER (WHERE c.variable = 'dfy')   AS dfy,
               MAX(c.value)      FILTER (WHERE c.variable = 'svar')  AS svar,
               MAX(c.period_end) FILTER (WHERE c.variable = 'price') AS price_period,
               MAX(c.period_end) FILTER (WHERE c.variable = 'd12')   AS d12_period,
               MAX(c.period_end) FILTER (WHERE c.variable = 'e12')   AS e12_period,
               MAX(c.period_end) FILTER (WHERE c.variable = 'tbl')   AS market_period
        FROM months m
        LEFT JOIN cur c ON c.month = m.month
        GROUP BY m.month
    ),
    raw AS (
        SELECT x.month,
               CASE WHEN x.d12 > 0 AND x.price > 0 THEN ln(x.d12) - ln(x.price) END AS dp,
               CASE WHEN x.e12 > 0 AND x.price > 0 THEN ln(x.e12) - ln(x.price) END AS ep,
               x.bm, x.ntis, x.tbl, x.tms, x.dfy, x.svar,
               x.price_period, x.d12_period, x.e12_period, x.market_period
        FROM wide x
    ),
    stats AS (
        SELECT r.*,
               AVG(r.dp)   OVER win AS dp_m,   STDDEV_SAMP(r.dp)   OVER win AS dp_s,   COUNT(r.dp)   OVER win AS dp_n,
               AVG(r.ep)   OVER win AS ep_m,   STDDEV_SAMP(r.ep)   OVER win AS ep_s,   COUNT(r.ep)   OVER win AS ep_n,
               AVG(r.bm)   OVER win AS bm_m,   STDDEV_SAMP(r.bm)   OVER win AS bm_s,   COUNT(r.bm)   OVER win AS bm_n,
               AVG(r.ntis) OVER win AS ntis_m, STDDEV_SAMP(r.ntis) OVER win AS ntis_s, COUNT(r.ntis) OVER win AS ntis_n,
               AVG(r.tbl)  OVER win AS tbl_m,  STDDEV_SAMP(r.tbl)  OVER win AS tbl_s,  COUNT(r.tbl)  OVER win AS tbl_n,
               AVG(r.tms)  OVER win AS tms_m,  STDDEV_SAMP(r.tms)  OVER win AS tms_s,  COUNT(r.tms)  OVER win AS tms_n,
               AVG(r.dfy)  OVER win AS dfy_m,  STDDEV_SAMP(r.dfy)  OVER win AS dfy_s,  COUNT(r.dfy)  OVER win AS dfy_n,
               AVG(r.svar) OVER win AS svar_m, STDDEV_SAMP(r.svar) OVER win AS svar_s, COUNT(r.svar) OVER win AS svar_n
        FROM raw r
        WINDOW win AS (ORDER BY r.month ROWS BETWEEN w PRECEDING AND CURRENT ROW)
    )
    SELECT s.month, s.dp, s.ep, s.bm, s.ntis, s.tbl, s.tms, s.dfy, s.svar,
           CASE WHEN s.dp   IS NOT NULL AND s.dp_n   >= p_min_months AND s.dp_s   > 0 THEN (s.dp   - s.dp_m)   / s.dp_s   END,
           CASE WHEN s.ep   IS NOT NULL AND s.ep_n   >= p_min_months AND s.ep_s   > 0 THEN (s.ep   - s.ep_m)   / s.ep_s   END,
           CASE WHEN s.bm   IS NOT NULL AND s.bm_n   >= p_min_months AND s.bm_s   > 0 THEN (s.bm   - s.bm_m)   / s.bm_s   END,
           CASE WHEN s.ntis IS NOT NULL AND s.ntis_n >= p_min_months AND s.ntis_s > 0 THEN (s.ntis - s.ntis_m) / s.ntis_s END,
           CASE WHEN s.tbl  IS NOT NULL AND s.tbl_n  >= p_min_months AND s.tbl_s  > 0 THEN (s.tbl  - s.tbl_m)  / s.tbl_s  END,
           CASE WHEN s.tms  IS NOT NULL AND s.tms_n  >= p_min_months AND s.tms_s  > 0 THEN (s.tms  - s.tms_m)  / s.tms_s  END,
           CASE WHEN s.dfy  IS NOT NULL AND s.dfy_n  >= p_min_months AND s.dfy_s  > 0 THEN (s.dfy  - s.dfy_m)  / s.dfy_s  END,
           CASE WHEN s.svar IS NOT NULL AND s.svar_n >= p_min_months AND s.svar_s > 0 THEN (s.svar - s.svar_m) / s.svar_s END,
           s.price_period, s.d12_period, s.e12_period, s.market_period
    FROM stats s
    WHERE s.month >= date_trunc('month', p_from)::DATE
    ORDER BY s.month;
END;
$$;

COMMENT ON FUNCTION macro.gkx_state(DATE, DATE, INTEGER, INTEGER) IS
    'The eight Gu-Kelly-Xiu macro predictors (Welch-Goyal definitions) per calendar month, point in time: '
    'raw, and z-scored against their own past only (expanding, or over p_window_months), NULL until '
    'p_min_months states exist. One row per month; join to a stock panel by month, never rank across stocks.';
