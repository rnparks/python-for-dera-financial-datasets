-- sql/00_reference/050_cover_share_count.sql
--
-- COVER-PAGE SHARE COUNTS FROM SEC'S XBRL API. Every 10-K and 10-Q states,
-- on its cover, the common shares outstanding on a date a few weeks after
-- the period end (dei:EntityCommonStockSharesOutstanding). It is the
-- filer's own point-in-time count, and DERA's Financial Statement Data
-- Sets almost never carry it: 917 such facts in all of sec_raw, against
-- one per filing here. Worse, DERA drops some filers' share facts whole:
-- Lockheed Martin's and General Dynamics' filings come through with USD
-- facts only (632 of 632 in Lockheed's 2026 Q2 10-Q), so neither had a
-- share count, or a market cap, on any date.
--
-- Loaded by `dera load-cover-shares` (dera_pipeline/cover_shares.py) from
-- SEC's frames API, one request per calendar quarter
-- (https://data.sec.gov/api/xbrl/frames/dei/EntityCommonStockSharesOutstanding/shares/CY2024Q2I.json),
-- which returns each filer's undimensioned cover count for the quarter
-- with its accession number. Kept for companies that were ever index
-- members. A per-class cover (Alphabet, Visa) is dimensioned and is not
-- in the frames; the share-class mapping covers those.
--
-- POINT IN TIME. A cover count is knowable with its filing: tradable_from
-- is the filing's, from sec_silver.sub_silver; a count whose filing is not
-- in DERA has no availability date and is not loaded.
--
-- HOW THE LADDER USES IT (sql/03_gold/055_shares_outstanding.sql): as a
-- referee, and as the last resort. A share count from the balance sheet
-- that both its own filing's cover count and its net income over EPS
-- contradict by more than a fifth is refused; and a company with no other
-- count gets the cover count. Nothing that agrees with its references
-- moves.
--
-- Not destructive: CREATE ... IF NOT EXISTS, so a silver rebuild leaves
-- the loaded rows alone.

CREATE TABLE IF NOT EXISTS sec_reference.cover_share_count (
    cik             INTEGER     NOT NULL,
    adsh            TEXT        NOT NULL,   -- the filing whose cover states the count
    cover_date      DATE        NOT NULL,   -- the date the count is as of
    shares          NUMERIC     NOT NULL,
    tradable_from   DATE        NOT NULL,   -- the filing's, from sub_silver
    frame           TEXT        NOT NULL,   -- the frames API period it came from, e.g. CY2024Q2I
    fetched_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (cik, adsh, cover_date),
    CHECK (shares > 0),
    CHECK (tradable_from >= cover_date - 400)
);
CREATE INDEX IF NOT EXISTS idx_cover_share_count_adsh ON sec_reference.cover_share_count (adsh);

COMMENT ON TABLE sec_reference.cover_share_count IS
    'Undimensioned cover-page share counts (dei:EntityCommonStockSharesOutstanding) from SEC''s XBRL '
    'frames API, for companies ever in an index, timed by their filing''s tradable_from '
    '(dera load-cover-shares). Referee and last resort for sec_gold.shares_outstanding_at.';
