-- Trading-session arithmetic.
--
-- One utility: shift_sessions(p_asof, p_sessions) moves a date back N
-- TRADING sessions using the dense session_seq, so a Friday minus one
-- lands on Thursday rather than on a weekend.
--
-- Callers pass their own buffer into it -- the as-of accessors in
-- 065_asof_functions.sql, shares_outstanding_at in 055 and
-- share_classes_at in 056 all expose it as p_buffer_sessions. The
-- reasoning for why a backtest wants that margin belongs with those
-- callers and is documented in 065; this file is only the arithmetic.

-- ---------------------------------------------------------------
-- Shift a knowledge date back N trading sessions.
-- ---------------------------------------------------------------
CREATE OR REPLACE FUNCTION sec_gold.shift_sessions(p_asof DATE, p_sessions INTEGER)
RETURNS DATE
LANGUAGE sql STABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN p_sessions IS NULL OR p_sessions <= 0 THEN p_asof
        ELSE (
            -- session_seq is dense, so "N sessions earlier" is one
            -- subtraction rather than a recursive date walk.
            SELECT c2.session_date
            FROM sec_reference.trading_calendar c2
            WHERE c2.session_seq = (
                SELECT MAX(c1.session_seq)
                FROM sec_reference.trading_calendar c1
                WHERE c1.session_date <= p_asof
            ) - p_sessions
        )
    END;
$$;

COMMENT ON FUNCTION sec_gold.shift_sessions(DATE, INTEGER) IS
    'Move a knowledge date back N trading sessions. Used to apply a '
    'backtest safety buffer without baking it into stored data.';
