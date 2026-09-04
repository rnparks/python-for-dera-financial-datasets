-- Single entry point replacing the old view_financials_pit and
-- view_financials_latest. The segments/coreg "consolidated only"
-- filter lives here exclusively; nothing downstream re-applies it.
--
-- Three modes now, and the third is the one backtests should use:
--
--   'asof'   -- what was knowable on p_asof. Requires p_asof. This is
--               the only mode that respects information availability.
--   'pit'    -- earliest sighting in the dataset, ignoring when that
--               sighting became knowable. Convenient, but a caller that
--               iterates over historical dates with this mode will read
--               facts filed after the date it is simulating.
--   'latest' -- the most recent restatement. Correct for "what do we
--               now believe", wrong for anything backtested.
--
-- Usage:
--   SELECT * FROM sec_silver.financials('asof', DATE '2015-06-30') WHERE cik = 320193;
--   SELECT * FROM sec_silver.financials('latest')                  WHERE cik = 320193;
--
-- Written in plpgsql so that a bad mode, or 'asof' without a date, is an
-- error. The earlier SQL-language version folded the missing date into
-- the WHERE clause and returned zero rows, which is exactly the silent
-- look-ahead-shaped failure the as-of discipline exists to prevent
-- (measured: financials('asof') for Apple returned 0 rows, no message).

DROP FUNCTION IF EXISTS sec_silver.financials(TEXT);
DROP FUNCTION IF EXISTS sec_silver.financials(TEXT, DATE);

CREATE OR REPLACE FUNCTION sec_silver.financials(
    p_mode TEXT DEFAULT 'latest',
    p_asof DATE DEFAULT NULL
)
RETURNS TABLE (
    cik            INTEGER,
    tag            TEXT,
    tlabel         TEXT,
    metric         TEXT,
    value_date     DATE,
    qtrs           INTEGER,
    uom            TEXT,
    value          NUMERIC,
    filed_date     DATE,
    known_at       TIMESTAMPTZ,
    tradable_from  DATE,
    vintage_seq    BIGINT,
    is_original_disclosure BOOLEAN,
    adsh           TEXT
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_mode NOT IN ('asof', 'pit', 'latest') THEN
        RAISE EXCEPTION 'financials: unknown mode %; use asof, pit or latest', p_mode
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_mode = 'asof' AND p_asof IS NULL THEN
        RAISE EXCEPTION 'financials(''asof'') requires a knowledge date; '
            'there is deliberately no default'
            USING ERRCODE = 'null_value_not_allowed';
    END IF;

    RETURN QUERY
    SELECT
        n.cik,
        n.tag,
        n.tlabel,
        n.tlabel AS metric,
        n.value_date,
        n.qtrs,
        n.uom,
        n.value,
        n.filed_date,
        n.known_at,
        n.tradable_from,
        n.vintage_seq,
        n.is_original_disclosure,
        n.adsh
    FROM sec_silver.num_silver n
    WHERE n.segments IS NULL
      AND n.coreg IS NULL
      AND (
          -- Exactly one vintage per fact key: the newest one that was
          -- already actionable on p_asof.
          (p_mode = 'asof'
              AND n.tradable_from <= p_asof
              AND (n.superseded_tradable > p_asof
                   OR n.superseded_tradable IS NULL))
       OR (p_mode = 'pit'    AND n.rank_pit    = 1)
       OR (p_mode = 'latest' AND n.rank_latest = 1)
      );
END;
$$;

COMMENT ON FUNCTION sec_silver.financials(TEXT, DATE) IS
    'Consolidated facts. Mode asof (with a date) is the only '
    'availability-correct option; pit and latest both ignore when a '
    'value became knowable. asof without a date raises.';
