-- Populate the security model from the staged events. Split from 041 so
-- the CSV load can sit between the staging DDL and the interpretation.

\set GRACE 180

INSERT INTO sec_reference.company_name (cik, name, valid_from, valid_to)
SELECT cik, name,
       COALESCE(NULLIF(valid_from,'')::date, DATE '1900-01-01'),
       NULLIF(valid_to,'')::date
FROM sec_reference.company_name_raw
WHERE name <> ''
ON CONFLICT DO NOTHING;

WITH ev AS (SELECT * FROM sec_reference.security_event_raw),
first_trade AS (
    -- An 8-A registers a class on an exchange, but it is the FIRST
    -- listing only if the company was not already public. The
    -- discriminator is behavioural, exactly as for delisting: if
    -- periodic reports predate the listing evidence, the company was
    -- already reporting, so the listing evidence describes a later
    -- class -- notes, preferred, a spinoff -- and not the common stock.
    --
    -- In that case the honest answer is a conservative upper bound: the
    -- company was tradable no later than its first EDGAR filing. Apple
    -- resolves to 1994 rather than 2014, which is late but true, instead
    -- of 2014, which is simply false.
    SELECT cik,
        CASE
            WHEN listing_evidence IS NOT NULL
             AND (first_periodic IS NULL OR first_periodic >= listing_evidence)
            THEN listing_evidence
            ELSE LEAST(COALESCE(first_filing, first_periodic),
                       COALESCE(first_periodic, first_filing))
        END AS first_trade_date,
        CASE
            WHEN listing_evidence IS NOT NULL
             AND (first_periodic IS NULL OR first_periodic >= listing_evidence)
            THEN CASE WHEN listing_evidence = first_ipo THEN '424B' ELSE '8-A' END
            WHEN first_periodic IS NOT NULL THEN 'already_reporting'
            ELSE 'first_edgar_filing'
        END AS basis
    FROM (
        SELECT b.*,
            -- Anchor the 8-A to the offering. A company can file an 8-A
            -- long before it actually lists: NVIDIA's earliest is
            -- 1998-03-23 against an IPO priced 1999-01-22, ten months
            -- later, which would have made it buyable before it traded.
            -- The right 8-A is the last one at or before the pricing --
            -- 1999-01-12 for NVIDIA, and still 2010-05-27 for Tesla,
            -- whose 8-A genuinely does sit a month ahead of its IPO.
            COALESCE(
                CASE WHEN b.first_ipo IS NOT NULL THEN (
                    SELECT MAX(e2.event_date) FROM ev e2
                    WHERE e2.cik = b.cik
                      AND e2.event_type = 'LISTING_REGISTRATION'
                      AND e2.event_date <= b.first_ipo
                ) END,
                b.first_ipo,
                b.first_8a
            ) AS listing_evidence
        FROM (
            SELECT cik,
                MIN(event_date) FILTER (WHERE event_type = 'LISTING_REGISTRATION') AS first_8a,
                MIN(event_date) FILTER (WHERE event_type = 'IPO_PRICING')          AS first_ipo,
                MIN(event_date) FILTER (WHERE event_type = 'PERIODIC_REPORT')      AS first_periodic,
                MIN(event_date) FILTER (WHERE event_type = 'FIRST_EDGAR_FILING')   AS first_filing
            FROM ev GROUP BY cik
        ) b
    ) b
),
delist AS (
    SELECT DISTINCT ON (n.cik)
        n.cik, n.event_date AS delisting_date, n.form, n.adsh
    FROM ev n
    WHERE n.event_type = 'DELISTING_NOTICE'
      AND NOT EXISTS (
          SELECT 1 FROM ev l WHERE l.cik = n.cik
            AND l.event_type = 'LISTING_REGISTRATION'
            AND l.event_date >= n.event_date)
      AND NOT EXISTS (
          SELECT 1 FROM ev p WHERE p.cik = n.cik
            AND p.event_type = 'PERIODIC_REPORT'
            AND p.event_date > n.event_date + :GRACE)
    ORDER BY n.cik, n.event_date
),
classes AS (
    -- One security per genuine share class where the issuer is mapped in
    -- the share_class allowlist, else a single '(common)' security. Same
    -- allowlist discipline as sec_gold.share_class_shares: an unmapped
    -- class yields nothing rather than a guess.
    SELECT ft.cik, COALESCE(sc.class_label, '(common)') AS class_label
    FROM first_trade ft
    LEFT JOIN (
        SELECT DISTINCT cik, class_label
        FROM sec_reference.share_class WHERE NOT is_excluded
    ) sc ON sc.cik = ft.cik
)
INSERT INTO sec_reference.security
    (cik, class_label, first_trade_date, first_trade_basis,
     delisting_date, is_provisional, source, source_detail)
SELECT c.cik, c.class_label, ft.first_trade_date, ft.basis,
       d.delisting_date,
       d.delisting_date IS NOT NULL
           AND d.delisting_date > CURRENT_DATE - :GRACE,
       'edgar_submissions',
       CASE WHEN d.adsh IS NOT NULL
            THEN 'delisting ' || d.form || ' ' || d.adsh END
FROM classes c
JOIN first_trade ft ON ft.cik = c.cik
LEFT JOIN delist   d ON d.cik  = c.cik
ON CONFLICT (cik, class_label) DO NOTHING;

INSERT INTO sec_reference.delisting_event
    (security_id, delisting_date, reason, is_provisional, source_form, source_adsh)
SELECT s.security_id, s.delisting_date, 'exchange_notice', s.is_provisional,
       split_part(replace(s.source_detail, 'delisting ', ''), ' ', 1),
       split_part(s.source_detail, ' ', 3)
FROM sec_reference.security s
WHERE s.delisting_date IS NOT NULL
ON CONFLICT DO NOTHING;

-- Listings. Multi-class securities take the ticker their mapping names;
-- single-class securities inherit the company's dated ticker intervals.
INSERT INTO sec_reference.listing (security_id, exchange, ticker, valid_from, valid_to, source)
SELECT s.security_id, NULL, sc.ticker,
       GREATEST(sc.effective_from, COALESCE(s.first_trade_date, sc.effective_from)),
       COALESCE(sc.effective_to, s.delisting_date),
       'share_class_map'
FROM sec_reference.security s
JOIN sec_reference.share_class sc
  ON sc.cik = s.cik AND sc.class_label = s.class_label AND sc.ticker IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO sec_reference.listing (security_id, exchange, ticker, valid_from, valid_to, source)
SELECT DISTINCT ON (s.security_id, ct.ticker)
       s.security_id, NULL, ct.ticker,
       GREATEST(ct.valid_from, COALESCE(s.first_trade_date, ct.valid_from)),
       COALESCE(ct.valid_to, s.delisting_date),
       'company_ticker'
FROM sec_reference.security s
JOIN sec_reference.company_ticker ct ON ct.cik = s.cik
WHERE s.class_label = '(common)'
ORDER BY s.security_id, ct.ticker, ct.valid_from
ON CONFLICT DO NOTHING;
