-- get_canonical(p_cik, p_concept, p_value_date, p_qtrs, p_mode)
--
-- Resolves a canonical concept to a single numeric value by walking
-- sec_gold.concept_tag_map in priority order. Industry-specific
-- entries (non-empty sic_prefix matching the company's SIC) beat
-- generic entries. The first matching tag with a non-null value for
-- the (cik, value_date, qtrs, rank) wins.
--
-- Mode:
--   'latest' → sec_silver.num_silver rank_latest=1 (restated, current)
--   'pit'    → sec_silver.num_silver rank_pit=1    (as-first-reported)

CREATE OR REPLACE FUNCTION sec_gold.get_canonical(
    p_cik         INTEGER,
    p_concept     TEXT,
    p_value_date  DATE,
    p_qtrs        INTEGER DEFAULT 4,
    p_mode        TEXT    DEFAULT 'latest'
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT n.value * m.sign_multiplier
    FROM sec_gold.concept_tag_map m
    JOIN sec_silver.num_silver    n ON n.tag = m.tag
    LEFT JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
    WHERE m.concept = p_concept
      AND n.cik = p_cik
      AND n.value_date = p_value_date
      AND n.qtrs = p_qtrs
      AND n.segments IS NULL AND n.coreg IS NULL
      AND (
          (p_mode = 'latest' AND n.rank_latest = 1)
       OR (p_mode = 'pit'    AND n.rank_pit    = 1)
      )
      AND (
          m.sic_prefix = ''
       OR s.sic::TEXT LIKE m.sic_prefix || '%'
      )
    ORDER BY
      m.sic_prefix <> '' DESC,   -- industry-specific overrides first
      m.priority        ASC
    LIMIT 1;
$$;


-- get_canonical_by_ticker — convenience wrapper that accepts a ticker
CREATE OR REPLACE FUNCTION sec_gold.get_canonical_by_ticker(
    p_ticker      TEXT,
    p_concept     TEXT,
    p_value_date  DATE,
    p_qtrs        INTEGER DEFAULT 4,
    p_mode        TEXT    DEFAULT 'latest'
) RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT sec_gold.get_canonical(
        (SELECT cik FROM sec_silver.ticker_map WHERE ticker = upper(p_ticker)),
        p_concept, p_value_date, p_qtrs, p_mode
    );
$$;
