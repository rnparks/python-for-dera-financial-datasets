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