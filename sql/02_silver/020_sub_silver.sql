-- Company metadata: one row per filing, plus the point-in-time
-- availability columns every downstream layer depends on.
--
-- Three date/time columns coexist here and they are NOT
-- interchangeable:
--
--   period_date   -- the fiscal period the filing reports on
--   filed_date    -- the SEC's official filing date. Provenance and
--                    reconciliation only. NEVER a backtest predicate:
--                    48% of filings are accepted after the market
--                    close yet carry that same day as filed_date.
--   known_at      -- the exact instant the filing became publicly
--                    readable on EDGAR. Ground truth.
--   tradable_from -- the first NYSE session on which an investor could
--                    actually act. The join key for backtests.
--
-- `accepted` is published by SEC in US Eastern. The previous cast to a
-- naive TIMESTAMP silently dropped that, which made every downstream
-- comparison zone-ambiguous.

CREATE TABLE sec_silver.sub_silver AS
WITH typed AS (
    SELECT
        adsh,
        cik::INTEGER                  AS cik,
        name,
        sic::INTEGER                  AS sic,
        countryba,
        stprba,
        cityba,
        zipba,
        bas1,
        form,
        period::DATE                  AS period_date,
        fy::INTEGER                   AS fy,
        fp,
        fye,
        filed::DATE                   AS filed_date,
        -- Interpret the naive SEC timestamp as Eastern, yielding a
        -- true instant.
        (accepted::TIMESTAMP AT TIME ZONE 'America/New_York')
                                      AS known_at,
        -- Diagnostic only. `prevrpt` means "was SUBSEQUENTLY amended",
        -- which is computed as of dataset publication and therefore
        -- encodes future knowledge. Filtering on it inside a backtest
        -- is itself look-ahead. Named to discourage that.
        NULLIF(prevrpt, '')::BOOLEAN  AS was_amended_later,
        NULLIF(detail, '')::BOOLEAN   AS is_detailed,
        NULLIF(nciks, '')::INTEGER    AS nciks,
        aciks
    FROM sec_raw.sub_raw
    WHERE adsh IS NOT NULL
)
SELECT
    t.*,
    cal.session_date AS tradable_from
FROM typed t
LEFT JOIN LATERAL (
    -- The first session whose closing bell rings strictly after the
    -- moment the filing landed. Same session when it arrived before
    -- the close, otherwise the next one, which rolls correctly across
    -- weekends, holidays and the ~40 half sessions where the bell is
    -- at 13:00.
    --
    -- Comparing the stored `close_at` instant keeps this a single
    -- indexed range scan. The earlier date-OR-time formulation could
    -- not use an index and turned this join into a seq scan of the
    -- calendar per filing.
    SELECT c.session_date
    FROM sec_reference.trading_calendar c
    WHERE c.close_at > t.known_at
    ORDER BY c.close_at
    LIMIT 1
) cal ON TRUE;

ALTER TABLE sec_silver.sub_silver ADD PRIMARY KEY (adsh);
CREATE INDEX idx_sub_cik           ON sec_silver.sub_silver (cik);
CREATE INDEX idx_sub_tradable_from ON sec_silver.sub_silver (tradable_from);
CREATE INDEX idx_sub_known_at      ON sec_silver.sub_silver (known_at);

COMMENT ON COLUMN sec_silver.sub_silver.filed_date IS
    'SEC official filing date. Provenance and reconciliation only. '
    'NOT an availability date - use tradable_from. Wrong for ~48% of '
    'filings, which are accepted after the close yet stamped that day.';
COMMENT ON COLUMN sec_silver.sub_silver.known_at IS
    'Instant the filing became publicly readable on EDGAR (from SEC '
    '`accepted`, interpreted as America/New_York).';
COMMENT ON COLUMN sec_silver.sub_silver.tradable_from IS
    'First NYSE session an investor could act on this filing. The '
    'correct join key for backtests.';
COMMENT ON COLUMN sec_silver.sub_silver.was_amended_later IS
    'SEC prevrpt flag. DIAGNOSTIC ONLY - it is computed as of dataset '
    'publication, so using it as a backtest filter is look-ahead.';
