-- Helper lookups for application/Python consumers.
--
-- TICKER RESOLUTION CAVEAT. The ticker-keyed functions below resolve
-- through `sec_silver.ticker_map`, which is SEC's CURRENT-STATE
-- crosswalk: it lists only companies registered with a ticker today, so
-- a ticker that has since been retired or reassigned does not resolve,
-- and a delisted company cannot be looked up by the symbol it traded
-- under. Measured on this data, today's file is missing 58.5% of 2013
-- filers.
--
-- The sibling matviews (030_tradable_financials, 035_fact_asof,
-- 056_share_class_shares) use `sec_reference.company_ticker`, which is
-- dated and survivorship-free. The split is historical, not intentional.
-- Anything doing research over past universes should resolve the CIK via
-- `sec_reference.cik_at(ticker, asof)` and call the CIK-keyed function.
--
-- Both functions read from the pit matview and join metric_aliases so
-- the display-name remapping that used to live in a hardcoded CASE is
-- now data-driven.

-- Explicit drop: CREATE OR REPLACE cannot change a RETURNS TABLE
-- shape, so editing this signature and re-applying the single file
-- against a live schema fails with "cannot change return type of
-- existing function". A full build-gold drops the schema first and
-- would not notice; the iteration loop does.
DROP FUNCTION IF EXISTS sec_gold.get_pit_financials(INTEGER);

CREATE OR REPLACE FUNCTION sec_gold.get_pit_financials(p_cik INTEGER)
RETURNS TABLE (
    value_date     DATE,
    filed_date     DATE,
    metric         TEXT,
    value_billions NUMERIC
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        tf.value_date,
        tf.filed_date,
        COALESCE(ma.display_name, tf.metric)          AS metric,
        (tf.value / 1000000000)::NUMERIC              AS value_billions
    FROM sec_gold.tradable_financials_pit tf
    LEFT JOIN sec_gold.metric_aliases ma ON ma.tag = tf.tag
    WHERE tf.cik = p_cik
      AND tf.qtrs = 4
      AND tf.tag IN (SELECT tag FROM sec_gold.metric_aliases)
    ORDER BY tf.value_date DESC;
$$;


DROP FUNCTION IF EXISTS sec_gold.get_financials_by_ticker(TEXT);

CREATE OR REPLACE FUNCTION sec_gold.get_financials_by_ticker(p_ticker TEXT)
RETURNS TABLE (
    value_date     DATE,
    filed_date     DATE,
    metric         TEXT,
    value_billions NUMERIC
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_cik INTEGER;
BEGIN
    SELECT cik INTO v_cik
    FROM sec_silver.ticker_map
    WHERE ticker = sec_gold.norm_ticker(p_ticker)
    LIMIT 1;

    IF v_cik IS NULL THEN
        RAISE EXCEPTION 'Ticker % not found in ticker_map.', p_ticker;
    END IF;

    RETURN QUERY
    SELECT * FROM sec_gold.get_pit_financials(v_cik);
END;
$$;
