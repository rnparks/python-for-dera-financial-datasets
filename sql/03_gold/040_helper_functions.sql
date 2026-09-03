-- Helper lookups for application/Python consumers.
--
-- Both functions read from the pit matview and join metric_aliases so
-- the display-name remapping that used to live in a hardcoded CASE is
-- now data-driven.

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
