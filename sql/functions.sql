-- Create a reusable function to fetch PIT financials
CREATE OR REPLACE FUNCTION sec_silver.get_pit_financials(p_cik INTEGER)
RETURNS TABLE (
    value_date DATE,
    filed_date DATE,
    metric TEXT,
    value_billions NUMERIC
) 
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        vp.value_date,
        vp.filed_date,
        -- Logic to clean up metric names
        CASE 
            WHEN vp.tag IN ('Revenues', 'RevenueFromContractWithCustomerExcludingAssessedTax') 
                THEN 'Total Revenue'::TEXT
            WHEN vp.tag IN ('NetIncomeLoss', 'NetIncomeLossAvailableToCommonStockholdersBasic') 
                THEN 'Net Income'::TEXT
            ELSE vp.tag::TEXT
        END as metric,
        
        -- Logic to convert to billions
        (vp.value / 1000000000)::NUMERIC as value_billions
    FROM sec_silver.view_financials_pit vp
    WHERE vp.cik = p_cik
      AND vp.qtrs = 4 
      AND vp.tag IN (
          'Revenues', 
          'RevenueFromContractWithCustomerExcludingAssessedTax',
          'NetIncomeLoss',
          'NetIncomeLossAvailableToCommonStockholdersBasic'
      )
    ORDER BY vp.value_date DESC;
END;
$$;



CREATE OR REPLACE FUNCTION sec_silver.get_financials_by_ticker(p_ticker TEXT)
RETURNS TABLE (
    value_date DATE,
    filed_date DATE,
    metric TEXT,
    value_billions NUMERIC
) 
LANGUAGE plpgsql
AS $$
DECLARE
    v_cik INTEGER;
BEGIN
    -- 1. Look up the CIK in the OFFICIAL table
    SELECT cik INTO v_cik
    FROM sec_silver.ticker_map
    WHERE ticker = upper(p_ticker)
    LIMIT 1; -- specific tickers might map to same CIK, take first

    -- 2. Handle invalid tickers
    IF v_cik IS NULL THEN
        RAISE EXCEPTION 'Ticker % not found in mapping table.', p_ticker;
    END IF;

    -- 3. Return the data
    RETURN QUERY
    SELECT * FROM sec_silver.get_pit_financials(v_cik);
END;
$$;