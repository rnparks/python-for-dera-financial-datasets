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
--
-- It RAISES rather than returning NULL when the shifted session does not
-- exist. The previous version returned NULL for any date before the
-- calendar's first session (2009-01-02), and every as-of accessor then
-- compared against NULL and returned an empty set with nothing to say
-- why. An accessor family built on "no default knowledge date" should
-- not have a silent-empty path in its arithmetic.

-- Signature unchanged; the body moves to plpgsql for the RAISE.
CREATE OR REPLACE FUNCTION sec_gold.shift_sessions(p_asof DATE, p_sessions INTEGER)
RETURNS DATE
LANGUAGE plpgsql STABLE PARALLEL SAFE AS $$
DECLARE
    v_seq  INTEGER;
    v_date DATE;
BEGIN
    IF p_asof IS NULL THEN
        RAISE EXCEPTION 'shift_sessions: the knowledge date is NULL; '
            'every as-of lookup requires one'
            USING ERRCODE = 'null_value_not_allowed';
    END IF;
    IF p_sessions IS NULL OR p_sessions <= 0 THEN
        RETURN p_asof;
    END IF;

    -- session_seq is dense, so "N sessions earlier" is one subtraction
    -- rather than a recursive date walk.
    SELECT MAX(c.session_seq) INTO v_seq
    FROM sec_reference.trading_calendar c
    WHERE c.session_date <= p_asof;

    SELECT c.session_date INTO v_date
    FROM sec_reference.trading_calendar c
    WHERE c.session_seq = v_seq - p_sessions;

    IF v_date IS NULL THEN
        RAISE EXCEPTION 'shift_sessions: no trading session % session(s) '
            'before % (the calendar starts %)',
            p_sessions, p_asof,
            (SELECT MIN(session_date) FROM sec_reference.trading_calendar)
            USING ERRCODE = 'no_data_found';
    END IF;
    RETURN v_date;
END;
$$;

COMMENT ON FUNCTION sec_gold.shift_sessions(DATE, INTEGER) IS
    'Move a knowledge date back N trading sessions. Used to apply a '
    'backtest safety buffer without baking it into stored data. Raises '
    'if the target session does not exist rather than returning NULL.';
