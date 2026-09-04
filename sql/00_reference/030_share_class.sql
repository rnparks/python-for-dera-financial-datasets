-- Share-class to ticker mapping.
--
-- WHY THIS EXISTS. Market capitalisation for a multi-class issuer is the
-- sum over classes of shares times THAT CLASS'S price. It cannot be
-- computed from a single collapsed share count, because the classes do
-- not trade together: GOOGL and GOOG sit a percent or two apart, but
-- BRK.A is roughly 1,500 times BRK.B.
--
-- WHY IT IS NOT *YET* DERIVED FROM FILINGS. The share counts are
-- filings-native and well populated. The class-to-ticker link is not
-- available from the sources this pipeline currently ingests, and that
-- was verified rather than assumed: SEC's submissions API returns
-- Alphabet's tickers as ['GOOGL','GOOG','GOOGM','GOOGN'] with no class
-- labels at all, and Berkshire's as ['BRK-B','BRK-A']. The cover-page
-- facts that would carry it, dei:TradingSymbol dimensioned by class, are
-- text rather than numeric, so they are absent from the DERA NUMERIC
-- datasets -- `grep -c TradingSymbol data/raw/2026q2/num.txt` returns 0.
--
-- That is a limitation of what we ingest, NOT a property of filings. The
-- cover page of every 10-K since 2019 does carry dei:TradingSymbol
-- dimensioned by StatementClassOfStockAxis, and the member string
-- matches num_silver.segments character for character (verified against
-- Alphabet). So the ~270 unmapped classes are derivable once a
-- cover-page ingest exists; hand-mapping is a current-state cost, not a
-- structural one. An earlier version of this header said "WHY IT IS NOT
-- DERIVED FROM FILINGS", which read as "cannot be" and was wrong.
--
-- WHY IT IS NOT INFERRED. Across the tracked universe, class count equals
-- listed-ticker count for almost none of the multi-class issuers.
-- Alphabet files three class labels against two tickers; News Corp three
-- against two; Liberty Broadband three against four. Any positional,
-- alphabetical or suffix-based inference is therefore guaranteed to
-- misalign somewhere, silently.
--
-- WHY A GENERIC SUM IS NOT AN OPTION EITHER. The ClassOfStock axis is
-- free text whose members routinely overlap. Tested against issuers that
-- publish both a consolidated total and clean per-class rows, summing
-- the classes disagreed with the total in 312 of 1,033 cases. Symbotic
-- files CommonClassA, CommonClassV1, CommonClassV3 *and* a combined
-- CommonClassV1AndV3; Kodiak files a redemption subset alongside its
-- parent; Xanadu files a literal TotalCommonShares member. This is why
-- the consuming matview joins to this table as an ALLOWLIST rather than
-- pattern-matching the label.
--
-- PROVENANCE. Every row records where it came from and, for anything
-- hand-mapped, the filing it was read from. Rows can be sourced from
-- filings, a vendor, or an exchange listing file; what matters is that
-- the source is declared per row so the table can be audited or
-- selectively re-derived rather than trusted wholesale.

CREATE SCHEMA IF NOT EXISTS sec_reference;

DROP TABLE IF EXISTS sec_reference.share_class CASCADE;

CREATE TABLE sec_reference.share_class (
    cik                 INTEGER NOT NULL,
    -- The ClassOfStock member exactly as SEC publishes it, minus the
    -- "ClassOfStock=" prefix and trailing semicolon. Stored verbatim so
    -- the join to num_silver.segments is exact rather than fuzzy.
    class_label         TEXT    NOT NULL,

    -- Exactly one of these three states must hold, enforced below.
    --
    --   ticker set             the class is itself listed; price directly
    --   prices_with_ticker set unlisted class, real equity, priced at the
    --                          class it converts into
    --   is_excluded            not common equity for market-cap purposes,
    --                          or a duplicate expression of another row
    ticker              TEXT,
    prices_with_ticker  TEXT,
    -- Shares of `prices_with_ticker` obtainable per share of this class.
    -- Usually 1. Must be cited in source_note, never assumed.
    conversion_ratio    NUMERIC,
    is_excluded         BOOLEAN NOT NULL DEFAULT FALSE,

    -- Tickers move between issuers and classes are created and retired,
    -- so the mapping is dated like everything else in sec_reference.
    -- Liberty Media alone has held 21 distinct tickers across its
    -- tracking-stock families.
    effective_from      DATE    NOT NULL DEFAULT DATE '1900-01-01',
    effective_to        DATE,

    source              TEXT    NOT NULL,
    source_note         TEXT,

    PRIMARY KEY (cik, class_label, effective_from),

    CONSTRAINT share_class_exactly_one_state CHECK (
        (ticker IS NOT NULL AND prices_with_ticker IS NULL AND NOT is_excluded)
     OR (ticker IS NULL AND prices_with_ticker IS NOT NULL AND NOT is_excluded)
     OR (ticker IS NULL AND prices_with_ticker IS NULL AND is_excluded)
    ),
    -- An unlisted class without a ratio would silently value at par with
    -- its reference class, which is an assumption, not a fact.
    CONSTRAINT share_class_ratio_required CHECK (
        prices_with_ticker IS NULL OR conversion_ratio IS NOT NULL
    ),
    CONSTRAINT share_class_source_known CHECK (
        source IN ('mapped_filing', 'mapped_exchange', 'mapped_vendor')
    )
);

CREATE INDEX idx_share_class_cik    ON sec_reference.share_class (cik);
CREATE INDEX idx_share_class_ticker ON sec_reference.share_class (ticker)
    WHERE ticker IS NOT NULL;

COMMENT ON TABLE sec_reference.share_class IS
    'Share-class to ticker mapping for multi-class issuers. Explicit '
    'exceptions only: single-class issuers are inferred deterministically '
    'in sec_gold.share_class_shares and need no row here.';
COMMENT ON COLUMN sec_reference.share_class.prices_with_ticker IS
    'For an unlisted class that is real equity, the listed class it '
    'converts into. Alphabet Class B is 849M shares with no ticker; '
    'dropping it understates market cap, pricing it at zero is worse.';
COMMENT ON COLUMN sec_reference.share_class.is_excluded IS
    'TRUE for members that are not common equity, or that restate '
    'another row. Berkshire publishes one total twice, in A-equivalent '
    'and B-equivalent units; counting both double counts the company.';
COMMENT ON COLUMN sec_reference.share_class.source IS
    'Where the mapping came from. Kept per row so a filing-sourced and '
    'a vendor-sourced mapping can coexist and be audited separately.';
