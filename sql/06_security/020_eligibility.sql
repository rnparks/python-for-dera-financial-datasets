-- Historical eligibility, and the accessor that reconstructs a universe
-- as of a date.
--
-- The first universe is `filers_10k_15m`: every security whose issuer had
-- an annual report ACTIONABLE within the trailing 15 months. It is
-- survivorship-free by construction -- the spine holds every CIK that
-- ever filed, so a company that failed is a member right up to the point
-- it stopped filing, and its delisting ends the interval rather than
-- erasing the history.
--
-- KEYED ON tradable_from, NEVER filed_date. 48% of filings are accepted
-- after the close and stamped that same filed_date; using it would
-- reintroduce precisely the leak commit a05ac89 removed. The universe
-- inherits the availability model rather than inventing a second one.
--
-- 15 months, not 12: annual report deadlines run 60-90 days past fiscal
-- year end, so a 12-month window would drop healthy late filers every
-- year. Long enough to tolerate lateness, short enough that a company
-- which stops filing leaves within about five quarters.

INSERT INTO sec_reference.eligibility
    (security_id, universe_name, valid_from, valid_to, reason_in, reason_out,
     sec_first_trade_date, sec_delisting_date)
WITH iv AS (
    SELECT s.security_id,
           sub.tradable_from                                  AS lo,
           (sub.tradable_from + INTERVAL '15 months')::date   AS hi
    FROM sec_reference.security s
    JOIN sec_silver.sub_silver sub ON sub.cik = s.cik
    WHERE (sub.form LIKE '10-K%' OR sub.form LIKE '20-F%' OR sub.form LIKE '40-F%')
      AND sub.tradable_from IS NOT NULL
),
ord AS (
    SELECT security_id, lo, hi,
           MAX(hi) OVER (PARTITION BY security_id ORDER BY lo, hi
                         ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING) AS prev_max_hi
    FROM iv
),
grp AS (
    -- Gaps and islands: a new island starts wherever this interval opens
    -- after every previous one has closed.
    SELECT *,
           COUNT(*) FILTER (WHERE prev_max_hi IS NULL OR lo > prev_max_hi)
               OVER (PARTITION BY security_id ORDER BY lo, hi ROWS UNBOUNDED PRECEDING) AS g
    FROM ord
),
merged AS (
    SELECT security_id, MIN(lo) AS lo, MAX(hi) AS hi
    FROM grp GROUP BY security_id, g
)
SELECT m.security_id, 'filers_10k_15m',
       -- Clipped to the security's own lifecycle. The two CHECK
       -- constraints on this table would reject an unclipped row, which
       -- is the point: the invariant is enforced, not merely intended.
       GREATEST(m.lo, s.first_trade_date),
       LEAST(m.hi, COALESCE(s.delisting_date, m.hi)),
       'annual_report_actionable_within_15m',
       -- reason_out is the reason the interval ENDS, and every interval
       -- has an end: valid_to is always set because eligibility runs out
       -- 15 months after the last annual report unless another one lands
       -- first. For an interval whose valid_to is still in the future
       -- this is therefore the reason it WILL end if nothing changes,
       -- not a statement that it has ended.
       CASE WHEN s.delisting_date IS NOT NULL AND s.delisting_date < m.hi
            THEN 'delisted'
            ELSE 'no_annual_report_within_15m' END,
       s.first_trade_date, s.delisting_date
FROM merged m
JOIN sec_reference.security s USING (security_id)
WHERE s.first_trade_date IS NOT NULL
  AND GREATEST(m.lo, s.first_trade_date)
      <= LEAST(m.hi, COALESCE(s.delisting_date, m.hi))
ON CONFLICT DO NOTHING;


-- The accessor. p_asof has NO DEFAULT, matching the as_of_* discipline
-- in gold: omitting the date is a call-site error, not a silent leak.
DROP FUNCTION IF EXISTS sec_reference.universe_at(TEXT, DATE);

CREATE FUNCTION sec_reference.universe_at(p_universe TEXT, p_asof DATE)
RETURNS TABLE (
    security_id  BIGINT,
    cik          INTEGER,
    class_label  TEXT,
    ticker         TEXT,
    ticker_is_asof BOOLEAN,
    company_name   TEXT,
    reason_in      TEXT
)
LANGUAGE sql STABLE AS $$
    SELECT e.security_id, s.cik, s.class_label,
           -- The ticker AS OF the date where one is known, else the
           -- security's earliest known symbol as a labelling fallback.
           --
           -- The crosswalk floor is 2019-02 (the archive's first capture
           -- of company_tickers.json), so a strict as-of lookup returns
           -- NULL for most of 2009-2019 and the universe loses its human
           -- labels across half its range. tradable_financials hit this
           -- exact trade and resolved it the same way: coalesce to the
           -- best-known symbol and publish a flag saying which you got,
           -- so a caller that needs a date-correct symbol can filter and
           -- everyone else gets a readable label.
           COALESCE(asof.ticker, fallback.ticker),
           asof.ticker IS NOT NULL,
           (SELECT cn.name FROM sec_reference.company_name cn
             WHERE cn.cik = s.cik
               AND cn.valid_from <= p_asof
               AND (cn.valid_to IS NULL OR cn.valid_to > p_asof)
             ORDER BY cn.valid_from DESC LIMIT 1),
           e.reason_in
    FROM sec_reference.eligibility e
    JOIN sec_reference.security s USING (security_id)
    -- Half-open on both sides, matching eligibility: a listing's
    -- valid_to is the first date the ticker was observed gone (or the
    -- delisting date), so it must not resolve ON that date.
    LEFT JOIN LATERAL (
        SELECT l.ticker FROM sec_reference.listing l
        WHERE l.security_id = s.security_id
          AND l.valid_from <= p_asof
          AND (l.valid_to IS NULL OR l.valid_to > p_asof)
        ORDER BY l.valid_from DESC LIMIT 1
    ) asof ON TRUE
    LEFT JOIN LATERAL (
        SELECT l.ticker FROM sec_reference.listing l
        WHERE l.security_id = s.security_id
        ORDER BY l.valid_from ASC LIMIT 1
    ) fallback ON TRUE
    WHERE e.universe_name = p_universe
      AND e.valid_from <= p_asof
      AND (e.valid_to IS NULL OR e.valid_to > p_asof);
$$;

COMMENT ON FUNCTION sec_reference.universe_at(TEXT, DATE) IS
    'Reconstruct a universe as of a date. Includes securities that later '
    'failed; excludes securities that had not yet listed. p_asof has no '
    'default so it cannot be omitted by accident.';
