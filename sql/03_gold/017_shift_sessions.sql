-- As-of accessors. The knowledge date has NO default anywhere in this
-- file, deliberately: omitting it must be a call-site error, not a
-- silent look-ahead. Every other accessor in gold defaults to something
-- convenient, and that is exactly how a backtest quietly reads the
-- future.
--
-- p_buffer_sessions is the safety margin, expressed in trading sessions
-- rather than calendar days so a Friday close plus one lands on Monday.
-- It defaults to 0, meaning "the earliest session an investor could
-- genuinely have acted". Re-run a strategy at 1, 2 and 5 to see how
-- fast the edge decays; one that dies at a single extra session was
-- never an edge.

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
