-- The index-membership universe: sp500.
--
-- One eligibility interval per (security, membership interval), for
-- every security of a member company -- both Alphabet classes were
-- S&P 500 constituents, and so were both Fox classes. Clipped to
-- the security's lifecycle by the same GREATEST/LEAST as the
-- filers_10k_15m universe, which is what the CHECK constraints demand.
--
-- reason_out records why the interval ends: 'index_removal' when the
-- page stopped listing the company while it was still trading,
-- 'delisted' when its security ended first. An interval still open in
-- the latest capture has reason_out NULL, unlike the filers universe
-- whose intervals always carry a scheduled end.
--
-- Only indexes with replayed history are turned into universes; a
-- current_snapshot membership is not a historical universe and would
-- reintroduce exactly the bias this file exists to remove.

-- Re-derivable: the filers universe is rebuilt with its tables, this one
-- is inserted into the shared eligibility table and must clear its own
-- rows first.
DELETE FROM sec_reference.eligibility WHERE universe_name = 'sp500';

INSERT INTO sec_reference.eligibility
    (security_id, universe_name, valid_from, valid_to, reason_in, reason_out,
     sec_first_trade_date, sec_delisting_date)
SELECT s.security_id,
       'sp500',
       GREATEST(m.valid_from, s.first_trade_date),
       LEAST(COALESCE(m.valid_to, DATE '9999-12-31'), COALESCE(s.delisting_date, DATE '9999-12-31')),
       'index_constituent',
       CASE WHEN s.delisting_date IS NOT NULL AND s.delisting_date <= COALESCE(m.valid_to, DATE '9999-12-31')
                 THEN 'delisted'
            WHEN m.valid_to IS NOT NULL THEN 'index_removal'
       END,
       s.first_trade_date, s.delisting_date
FROM (
    -- Merge the per-GICS intervals back into one membership span per
    -- company: a reclassification is not an exit.
    SELECT index_name, cik, MIN(valid_from) AS valid_from,
           CASE WHEN bool_or(valid_to IS NULL) THEN NULL ELSE MAX(valid_to) END AS valid_to
    FROM (
        SELECT m.*, SUM(CASE WHEN m.valid_from > COALESCE(prev_to, DATE '1900-01-01') THEN 1 ELSE 0 END)
                        OVER (PARTITION BY index_name, cik ORDER BY valid_from) AS span
        FROM (SELECT m.*, MAX(COALESCE(valid_to, DATE '9999-12-31'))
                              OVER (PARTITION BY index_name, cik ORDER BY valid_from
                                    ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_to
              FROM sec_reference.index_membership m
              WHERE m.index_name = 'SP500' AND m.source = 'wikipedia_history') m
    ) x
    GROUP BY index_name, cik, span
) m
JOIN sec_reference.security s ON s.cik = m.cik
-- No listing requirement: a member that delisted before the crosswalk's
-- 2019 floor has no listing row and no ticker label, but it was in the
-- index and it is in this universe (60 of the 2015 members are in that
-- position). Unlisted share classes are not securities, so nothing
-- non-tradable slips in this way.
WHERE s.first_trade_date IS NOT NULL
  AND GREATEST(m.valid_from, s.first_trade_date)
      <= LEAST(COALESCE(m.valid_to, DATE '9999-12-31'), COALESCE(s.delisting_date, DATE '9999-12-31'))
ON CONFLICT DO NOTHING;

-- A NULL valid_to is not allowed by the sp500 CHECK when the security
-- has delisted, and the LEAST above guarantees that; but an OPEN
-- membership on a LIVE security must be NULL rather than 9999-12-31 so
-- universe_at's `valid_to > p_asof` reads it as current.
UPDATE sec_reference.eligibility
SET valid_to = NULL
WHERE universe_name = 'sp500' AND valid_to = DATE '9999-12-31';
