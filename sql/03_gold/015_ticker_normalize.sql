-- Ticker normalization, defined once.
--
-- `dera_pipeline/reference.py` rewrites class-share tickers from dot to
-- hyphen on ingest, matching SEC's own convention: BRK.B is stored as
-- BRK-B, BF.B as BF-B. The gold lookup functions did not apply the same
-- rule, so they compared a caller's input directly against the stored
-- form.
--
-- The result was a silent wrong answer rather than an error. Verified
-- against the live crosswalk: `BRK.B` matches 0 rows, `BRK-B` matches 1,
-- and no dotted ticker is stored anywhere. Every caller passing
-- Bloomberg, Yahoo or ordinary human notation got an empty result with
-- nothing to indicate why.
--
-- Centralized here so the rule has one definition. If normalization ever
-- needs to grow, for example handling whitespace inside a symbol or ADR
-- suffixes, it changes in one place instead of three call sites.

CREATE OR REPLACE FUNCTION sec_gold.norm_ticker(p_ticker TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT REPLACE(UPPER(TRIM(p_ticker)), '.', '-');
$$;

COMMENT ON FUNCTION sec_gold.norm_ticker(TEXT) IS
    'Normalize a ticker to stored form: trim, uppercase, dots to '
    'hyphens (BRK.B -> BRK-B). Use in every ticker lookup.';
