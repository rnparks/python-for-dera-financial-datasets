-- sql/00_reference/035_share_unit.sql
--
-- AN ISSUER THAT STATES THE WHOLE COMPANY IN ANOTHER CLASS'S UNITS.
-- Berkshire Hathaway's income statement reports "Average equivalent
-- Class A shares outstanding" and "Net earnings per equivalent Class A
-- share": both classes together, each Class B share counted as a
-- fifteen-hundredth of an A (FY2015 10-K, 0001193125-16-483023: "Average
-- shares outstanding and net earnings per share are shown on an
-- equivalent Class A common stock basis. Equivalent Class B shares
-- outstanding are 1,500 times the equivalent Class A amount"). Until 2015
-- the count is undimensioned, and in 2016-2017 it is tagged
-- ClassOfStock=CommonClassA; either way it is the whole company in
-- A units. Read as shares and priced at BRK-B, it made Berkshire a
-- $230 million company (1,643,316 shares at $140) on every date from
-- 2010 to 2017, against about $345 billion.
--
-- A row says: in this issuer's filings tradable in [filed_from,
-- filed_to), the weighted-average share counts that are undimensioned or
-- tagged ClassOfStock=<unit_member>, and the basic EPS that is
-- undimensioned or tagged with that member, are per unit of the whole
-- company; one unit is shares_per_unit shares of priced_ticker, on the
-- split basis of the filing. sec_gold.shares_outstanding_at
-- (sql/03_gold/055_shares_outstanding.sql) multiplies those counts by it,
-- reads that EPS as per unit when it checks a count's scale, and does
-- not use the issuer's other undimensioned share counts in those filings,
-- whose unit the filer does not state (Berkshire's undimensioned cover
-- count is its Class A shares alone).
--
-- KEYED ON THE FILING, NOT THE PERIOD. A count is on the split basis of
-- the day its filing became tradable (sec_market.market_cap_at). Class B
-- split 50 for 1 on 2010-01-21, so an A unit was 30 B before it and
-- 1,500 after, and the 10-K filed 2010-03-01 states 2009 in units worth
-- 1,500 post-split B. A filing outside every row is read as filed: from
-- 2017-11-06 Berkshire tags its A-equivalent and B-equivalent counts as
-- ClassOfStock=EquivalentClassA and EquivalentClassB, which
-- sec_reference.share_class maps (A excluded, B priced at BRK-B).
--
-- Loaded from data/reference/share_unit.csv by `dera rebuild-reference`
-- (dera_pipeline/reference.py, load_share_units), each row citing the
-- filing sentence that states the unit and the conversion rate.

CREATE SCHEMA IF NOT EXISTS sec_reference;

DROP TABLE IF EXISTS sec_reference.share_unit;

CREATE TABLE sec_reference.share_unit (
    cik              INTEGER NOT NULL,
    -- The ClassOfStock member the filer tags the whole-company figures
    -- with in some filings, as in num_silver.segments minus the
    -- "ClassOfStock=" prefix and trailing semicolon.
    unit_member      TEXT    NOT NULL,
    priced_ticker    TEXT    NOT NULL,
    shares_per_unit  NUMERIC NOT NULL,
    filed_from       DATE    NOT NULL,   -- on the filing's tradable_from
    filed_to         DATE,               -- exclusive; NULL means still in force
    source_note      TEXT    NOT NULL,
    PRIMARY KEY (cik, filed_from),
    CONSTRAINT share_unit_ratio CHECK (shares_per_unit > 0 AND shares_per_unit <> 1),
    CONSTRAINT share_unit_window CHECK (filed_to IS NULL OR filed_to > filed_from),
    CONSTRAINT share_unit_cited CHECK (length(trim(source_note)) > 0),
    CONSTRAINT share_unit_member CHECK (length(trim(unit_member)) > 0)
);

COMMENT ON TABLE sec_reference.share_unit IS
    'Issuers whose weighted-average share counts and basic EPS state the whole company per unit of '
    'one class (Berkshire: per equivalent Class A share), by filing date: one unit is shares_per_unit '
    'shares of priced_ticker. Read by sec_gold.shares_outstanding_at. Each row cites its filing.';
