-- Display-name overrides for the get_pit_financials helper.
--
-- The legacy sql/functions.sql baked this mapping into a CASE expression
-- inside get_pit_financials. Moving it to a table means new aliases can
-- be added with an INSERT instead of an ALTER FUNCTION.
CREATE TABLE sec_gold.metric_aliases (
    tag          TEXT PRIMARY KEY,
    display_name TEXT NOT NULL
);

INSERT INTO sec_gold.metric_aliases (tag, display_name) VALUES
    ('Revenues',                                              'Total Revenue'),
    ('RevenueFromContractWithCustomerExcludingAssessedTax',   'Total Revenue'),
    ('NetIncomeLoss',                                         'Net Income'),
    ('NetIncomeLossAvailableToCommonStockholdersBasic',       'Net Income');
