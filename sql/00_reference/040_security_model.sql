-- The security model: company, security, listing, eligibility, outcome.
--
-- WHY THIS EXISTS. The pipeline is point-in-time correct on FACTS and not
-- on SECURITIES. `sec_gold.fact_asof` knows what any number looked like on
-- any date, but nothing knows when a security began trading or stopped, so
-- a historical universe cannot exclude a company before its IPO
-- (future-existence bias) nor retain it through its delisting
-- (survivorship bias). Measured on this database: 6,674 CIKs filed a 10-K
-- in 2015, but only 1,249 of today's 1,593 S&P universe CIKs were among
-- them, and SVB Financial, Sears, Bed Bath and Twitter are all absent from
-- the current universe while sitting in the 17,015-CIK spine.
--
-- THE CENTRAL DISTINCTION. A company is not a security. `company_ticker`
-- conflates them: it maps CIK to ticker with no notion of a tradable
-- instrument having a beginning and an end. Everything here hangs off
-- `security`, so "was this tradable on date T" is answerable.
--
-- TWO INVARIANTS, ENFORCED STRUCTURALLY. Following the same reasoning as
-- the share_class allowlist -- make the bad state impossible rather than
-- filter against it:
--
--   1. No eligibility interval may begin before first_trade_date.
--      This is the structural block on future-existence bias.
--   2. No eligibility interval may extend past delisting_date.
--      A delisted security stops being tradable; its outcome is recorded
--      in delisting_event rather than the row silently disappearing.
--
-- Both are declarative. `eligibility` carries the security's lifecycle
-- dates denormalised, bound to the parent row by a composite foreign key
-- with ON UPDATE CASCADE, so the CHECK constraints below cannot drift out
-- of agreement with `security`. A trigger would have worked; a constraint
-- cannot be forgotten.

CREATE SCHEMA IF NOT EXISTS sec_reference;

DROP TABLE IF EXISTS sec_reference.eligibility      CASCADE;
DROP TABLE IF EXISTS sec_reference.corporate_action CASCADE;
DROP TABLE IF EXISTS sec_reference.delisting_event  CASCADE;
DROP TABLE IF EXISTS sec_reference.listing          CASCADE;
DROP TABLE IF EXISTS sec_reference.security         CASCADE;
DROP TABLE IF EXISTS sec_reference.company_name     CASCADE;

-- Historical names, so a renamed company stays one identity. Sourced from
-- the submissions API `formerNames` block. Bed Bath & Beyond is the case
-- that motivates it: CIK 886158 is now named "20230930-DK-Butterfly-1,
-- Inc." while a DIFFERENT registrant, CIK 1130713, has since carried the
-- Bed Bath name. Matching on current name alone merges two companies.
CREATE TABLE sec_reference.company_name (
    cik         INTEGER NOT NULL,
    name        TEXT    NOT NULL,
    valid_from  DATE    NOT NULL DEFAULT DATE '1900-01-01',
    valid_to    DATE,
    PRIMARY KEY (cik, name, valid_from)
);

CREATE TABLE sec_reference.security (
    security_id        BIGSERIAL PRIMARY KEY,
    cik                INTEGER NOT NULL,
    -- '(common)' for a single-class issuer, else the ClassOfStock member
    -- exactly as SEC publishes it, matching sec_reference.share_class.
    class_label        TEXT    NOT NULL,
    security_type      TEXT    NOT NULL DEFAULT 'common_equity',

    -- When the security first became tradable, and on what evidence.
    -- basis is recorded because the sources are not equally strong:
    -- an 8-A is a real listing registration, a 424B4 is a pricing, and a
    -- first EDGAR filing is only a floor on company existence and is NOT
    -- a trading date. Anything relying on the last one should say so.
    --
    -- 'already_reporting' deserves the same scepticism, and an earlier
    -- comment here overstated it as a conservative upper bound. It is
    -- conservative for Apple (listed 1980, first EDGAR filing 1994: late
    -- but true). It is EARLY for a company that filed periodic reports
    -- before its equity traded -- a debt-only registrant, a bank holding
    -- company reporting under 12(g) -- and filings alone cannot tell
    -- those apart from OTC-quoted companies that later uplisted. Measured
    -- 2026-09-04: of 8,945 securities on this basis, 1,756 have a 424B
    -- pricing AFTER first_trade_date and 1,101 more than three years
    -- after. first_pricing_date below carries that evidence so a stricter
    -- universe can prefer it.
    first_trade_date   DATE,
    first_trade_basis  TEXT CHECK (first_trade_basis IN
                          ('8-A','424B','already_reporting','first_edgar_filing')),
    -- Earliest 424B1/424B4 pricing for the issuer, whatever its relation
    -- to first_trade_date. Evidence, not interpretation: 424B4 also
    -- prices follow-on and debt offerings, so it is not a trade date on
    -- its own.
    first_pricing_date DATE,

    delisting_date     DATE,
    -- TRUE when the delisting is too recent for the confirming evidence
    -- (absence of a following periodic report) to have had time to exist.
    is_provisional     BOOLEAN NOT NULL DEFAULT FALSE,

    source             TEXT    NOT NULL,
    source_detail      TEXT,

    UNIQUE (cik, class_label),
    CONSTRAINT security_lifecycle_ordered
        CHECK (delisting_date IS NULL OR first_trade_date IS NULL
               OR delisting_date >= first_trade_date)
);

-- Referenced by the composite FK on eligibility below. security_id alone
-- is already unique; the extra columns exist so the child can bind to the
-- lifecycle dates and CHECK against them declaratively.
ALTER TABLE sec_reference.security
    ADD CONSTRAINT security_lifecycle_key
    UNIQUE (security_id, first_trade_date, delisting_date);

CREATE INDEX idx_security_cik ON sec_reference.security (cik);

CREATE TABLE sec_reference.listing (
    security_id  BIGINT NOT NULL
                 REFERENCES sec_reference.security (security_id) ON DELETE CASCADE,
    exchange     TEXT,
    ticker       TEXT   NOT NULL,
    valid_from   DATE   NOT NULL,
    valid_to     DATE,
    source       TEXT   NOT NULL,
    PRIMARY KEY (security_id, ticker, valid_from),
    CONSTRAINT listing_interval_ordered
        CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE INDEX idx_listing_ticker ON sec_reference.listing (ticker, valid_from);

-- A delisting is an investment event, not missing data. delisting_return
-- and final_value are declared now and stay NULL until a price source
-- exists; leaving them out would have meant reshaping the table later,
-- and leaving them at 0 would assert a total loss that is usually false.
--
-- reason records the EVIDENCE CLASS, not the business cause. Two are
-- populated today: 'exchange_notice' (a Form 25 that the going-concern
-- rule accepted) and 'deregistration' (a Form 15 with no Form 25 -- the
-- company went dark without an exchange delisting; 2,207 CIKs fit this
-- shape and had no outcome row at all before). Acquisition, bankruptcy,
-- merger and liquidation need 8-K item parsing and remain future work;
-- the values are reserved so the column does not need reshaping.
CREATE TABLE sec_reference.delisting_event (
    security_id      BIGINT NOT NULL
                     REFERENCES sec_reference.security (security_id) ON DELETE CASCADE,
    delisting_date   DATE   NOT NULL,
    reason           TEXT   NOT NULL CHECK (reason IN
                        ('exchange_notice','deregistration','acquisition',
                         'bankruptcy','merger','liquidation','unknown')),
    is_provisional   BOOLEAN NOT NULL DEFAULT FALSE,
    source_form      TEXT,
    source_adsh      TEXT,
    delisting_return NUMERIC,
    final_value      NUMERIC,
    PRIMARY KEY (security_id, delisting_date)
);

CREATE TABLE sec_reference.corporate_action (
    security_id    BIGINT NOT NULL
                   REFERENCES sec_reference.security (security_id) ON DELETE CASCADE,
    effective_date DATE   NOT NULL,
    action_type    TEXT   NOT NULL,
    terms          JSONB,
    source         TEXT   NOT NULL,
    PRIMARY KEY (security_id, effective_date, action_type)
);

CREATE TABLE sec_reference.eligibility (
    security_id          BIGINT NOT NULL,
    universe_name        TEXT   NOT NULL,
    valid_from           DATE   NOT NULL,
    valid_to             DATE,
    -- Spec 12: the system must be able to say WHY a security entered and
    -- left. These are not decoration; a universe that cannot explain
    -- itself cannot be audited.
    reason_in            TEXT   NOT NULL,
    reason_out           TEXT,

    sec_first_trade_date DATE,
    sec_delisting_date   DATE,

    PRIMARY KEY (security_id, universe_name, valid_from),

    -- Plain FK first: a composite FK with a NULL member is not checked
    -- under MATCH SIMPLE, so an active security (NULL delisting_date)
    -- would otherwise escape referential checking entirely.
    FOREIGN KEY (security_id)
        REFERENCES sec_reference.security (security_id) ON DELETE CASCADE,
    FOREIGN KEY (security_id, sec_first_trade_date, sec_delisting_date)
        REFERENCES sec_reference.security
                   (security_id, first_trade_date, delisting_date)
        ON UPDATE CASCADE,

    CONSTRAINT eligibility_not_before_first_trade
        CHECK (sec_first_trade_date IS NOT NULL
               AND valid_from >= sec_first_trade_date),
    CONSTRAINT eligibility_not_after_delisting
        CHECK (sec_delisting_date IS NULL
               OR (valid_to IS NOT NULL AND valid_to <= sec_delisting_date)),
    CONSTRAINT eligibility_interval_ordered
        CHECK (valid_to IS NULL OR valid_to >= valid_from)
);

CREATE INDEX idx_eligibility_lookup ON sec_reference.eligibility
    (universe_name, valid_from, valid_to);

COMMENT ON TABLE sec_reference.security IS
    'A tradable instrument, distinct from the company that issues it. '
    'first_trade_date blocks future-existence bias; delisting_date ends '
    'tradability and hands the outcome to delisting_event.';
COMMENT ON COLUMN sec_reference.security.first_trade_basis IS
    'Evidence class: 8-A is a listing registration, 424B a pricing, '
    'already_reporting the first periodic report (early for debt-only '
    'registrants that listed equity later), and first_edgar_filing only '
    'a floor on company existence -- not a trading date. Flagged so '
    'callers can exclude or tighten by basis.';
COMMENT ON COLUMN sec_reference.security.first_pricing_date IS
    'Earliest 424B1/424B4 pricing on the issuer. Evidence only: also '
    'covers follow-on and debt offerings. GREATEST(first_trade_date, '
    'first_pricing_date) is the strict alternative for already_reporting '
    'securities.';
COMMENT ON COLUMN sec_reference.delisting_event.reason IS
    'Evidence class of the outcome: exchange_notice (Form 25) or '
    'deregistration (Form 15 with no Form 25, i.e. went dark). The '
    'business cause (acquisition, bankruptcy, ...) is not derived yet.';
COMMENT ON COLUMN sec_reference.delisting_event.delisting_return IS
    'NULL until a price source exists. Left NULL rather than 0 because a '
    'zero would assert a total loss, which is wrong for an acquisition.';
