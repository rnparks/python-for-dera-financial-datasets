-- peer_stats_asof(p_index, p_asof, p_max_age_days, p_buffer_sessions)
--
-- THE KNOWLEDGE-DATE CROSS-SECTION. peer_stats (080) is a fiscal-year
-- panel as now understood: restated values, moments over the finished
-- panel, and a tradable_from that is the restated vintage's date (97%
-- of FY2024 revenue rows carry the following year's comparative). It
-- cannot be lagged into a backtest. This function is the object a
-- backtest wants: for a knowledge date T, every constituent of an index
-- on T, each with the latest annual flows and latest balance sheet that
-- were ACTIONABLE by T -- first-disclosure availability, from fact_asof
-- -- and peer moments computed only over what was knowable then.
--
-- A FUNCTION, NOT A TABLE, on purpose. Materialising every month since
-- 2009 would be ~200 dates of ~30K rows and a table nobody asked for;
-- computed on demand the S&P 500 takes a few seconds warm (20 s for the
-- whole 6,445-company filer universe, measured 2026-09-04). A past T's
-- knowable set never changes once its quarters are loaded, so a cache
-- keyed by T would be safe if one is ever needed. None is.
--
-- STALENESS IS A COLUMN, NOT A SURPRISE. On 15 February a December
-- filer has FY2023 annual figures while a September filer has FY2024;
-- that is what the world looked like, and days_stale says so per row.
-- A figure older than p_max_age_days (default 550: a full fiscal year
-- plus the 10-K deadline, with room) is left out of the cross-section
-- rather than scored against fresher peers.
--
-- RESOLUTION MIRRORS as_of_latest_annual, set-based: every annual
-- period knowable at T per (company, concept), the best tag per period
-- (industry rows first), formulas assembled per period from operands
-- that share it, filed beating reconstruction at the same period, the
-- newest period winning; ratios at the numerator's period and growth
-- against the period one year back, both only from positive bases.
-- Every operand is bounded by the one knowledge date.
DROP FUNCTION IF EXISTS sec_gold.peer_stats_asof(TEXT, DATE, INTEGER, INTEGER);

CREATE FUNCTION sec_gold.peer_stats_asof(
    p_index            TEXT,
    p_asof             DATE,
    p_max_age_days     INTEGER DEFAULT 550,
    p_buffer_sessions  INTEGER DEFAULT 0
)
RETURNS TABLE (
    cik               INTEGER,
    ticker            TEXT,
    index_name        TEXT,
    gics_sector       TEXT,
    gics_sub_industry TEXT,
    peer_level        TEXT,
    peer_group        TEXT,
    concept           TEXT,
    fact_type         TEXT,
    value_date        DATE,
    tradable_from     DATE,
    days_stale        INTEGER,
    value             NUMERIC,
    peer_count        BIGINT,
    peer_mean         NUMERIC,
    peer_stddev       NUMERIC,
    peer_min          NUMERIC,
    peer_max          NUMERIC,
    zscore            NUMERIC,
    peer_percentile   NUMERIC
)
LANGUAGE sql STABLE AS $$
WITH k AS (
    SELECT sec_gold.shift_sessions(p_asof, p_buffer_sessions) AS d
),
members AS (
    -- Constituents ON the knowledge date, GICS as of it, ticker as of it.
    SELECT m.cik,
           COALESCE(sec_reference.ticker_at(m.cik, p_asof), m.ticker) AS ticker,
           p_index AS index_name, m.gics_sector, m.gics_sub_industry
    FROM sec_reference.index_members(p_index, p_asof) m
),
-- Every annual period knowable at k, best tag per (company, concept,
-- period). Bounded below so growth has one prior year to look at and
-- nothing older is dragged through the sort.
hist_direct AS (
    SELECT DISTINCT ON (f.cik, m.concept, f.value_date)
           f.cik, m.concept, f.value_date, f.tradable_from,
           f.value * m.sign_multiplier AS value
    FROM members mb
    JOIN sec_gold.concept_tag_map    m  ON TRUE
    JOIN sec_gold.canonical_concepts c  ON c.concept = m.concept
                                        AND c.fact_type IN ('flow', 'balance')
    JOIN sec_gold.fact_asof          f  ON f.cik = mb.cik AND f.tag = m.tag
                                        AND f.qtrs = CASE WHEN c.fact_type = 'balance' THEN 0 ELSE 4 END
    LEFT JOIN sec_reference.company  co ON co.cik = f.cik
    CROSS JOIN k
    WHERE f.value IS NOT NULL
      AND f.tradable_from <= k.d
      AND (f.superseded_tradable > k.d OR f.superseded_tradable IS NULL)
      AND f.value_date >  p_asof - (p_max_age_days + 430)
      AND f.value_date <= p_asof
      AND (m.sic_prefix = '' OR co.sic_latest::TEXT LIKE m.sic_prefix || '%')
    ORDER BY f.cik, m.concept, f.value_date, m.sic_prefix <> '' DESC, m.priority ASC
),
-- Formulas per period, from operands that share the period. A missing
-- required operand means no row for that period, as everywhere else.
hist_derived AS (
    SELECT h.cik, fm.concept, h.value_date,
           MAX(h.tradable_from)             AS tradable_from,
           SUM(fm.coefficient * h.value)    AS value
    FROM sec_gold.concept_formula fm
    JOIN hist_direct h ON h.concept = fm.operand
    GROUP BY h.cik, fm.concept, h.value_date
    HAVING COUNT(*) FILTER (WHERE fm.required)
         = (SELECT COUNT(*) FROM sec_gold.concept_formula f2
             WHERE f2.concept = fm.concept AND f2.required)
),
hist AS (
    SELECT DISTINCT ON (cik, concept, value_date)
           cik, concept, value_date, tradable_from, value
    FROM (
        SELECT cik, concept, value_date, tradable_from, value, 0 AS pref FROM hist_direct
        UNION ALL
        SELECT cik, concept, value_date, tradable_from, value, 1 FROM hist_derived
    ) u
    ORDER BY cik, concept, value_date, pref
),
latest AS (
    SELECT DISTINCT ON (cik, concept) cik, concept, value_date, tradable_from, value
    FROM hist
    ORDER BY cik, concept, value_date DESC
),
ratios AS (
    SELECT n.cik, r.concept, n.value_date,
           GREATEST(n.tradable_from, d.tradable_from) AS tradable_from,
           n.value / d.value AS value
    FROM sec_gold.concept_ratio r
    JOIN latest n ON n.concept = r.numerator
    JOIN hist   d ON d.cik = n.cik AND d.concept = r.denominator AND d.value_date = n.value_date
    WHERE r.kind = 'ratio' AND d.value > 0
),
growth AS (
    SELECT DISTINCT ON (n.cik, r.concept)
           n.cik, r.concept, n.value_date,
           GREATEST(n.tradable_from, b.tradable_from) AS tradable_from,
           (n.value - b.value) / b.value AS value
    FROM sec_gold.concept_ratio r
    JOIN latest n ON n.concept = r.numerator
    JOIN hist   b ON b.cik = n.cik AND b.concept = r.numerator
                 AND n.value_date - b.value_date BETWEEN 300 AND 430
    WHERE r.kind = 'growth' AND b.value > 0
    ORDER BY n.cik, r.concept, b.value_date DESC
),
resolved AS (
    SELECT * FROM latest
    UNION ALL SELECT * FROM ratios
    UNION ALL SELECT * FROM growth
),
fresh AS (
    SELECT mb.cik, mb.ticker, mb.index_name, mb.gics_sector, mb.gics_sub_industry,
           r.concept, c.fact_type, r.value_date, r.tradable_from,
           (p_asof - r.value_date)::INTEGER AS days_stale, r.value
    FROM resolved r
    JOIN members mb ON mb.cik = r.cik
    JOIN sec_gold.canonical_concepts c ON c.concept = r.concept
    WHERE p_asof - r.value_date <= p_max_age_days
),
levelled AS (
    SELECT f.*, 'sector'::TEXT AS peer_level, f.gics_sector AS peer_group
    FROM fresh f WHERE f.gics_sector IS NOT NULL
    UNION ALL
    SELECT f.*, 'sub_industry'::TEXT, f.gics_sub_industry
    FROM fresh f WHERE f.gics_sub_industry IS NOT NULL
),
moments AS (
    SELECT concept, peer_level, peer_group,
           COUNT(*)                    AS peer_count,
           AVG(value)::NUMERIC         AS peer_mean,
           STDDEV_SAMP(value)::NUMERIC AS peer_stddev,
           MIN(value)::NUMERIC         AS peer_min,
           MAX(value)::NUMERIC         AS peer_max
    FROM levelled
    GROUP BY concept, peer_level, peer_group
    HAVING COUNT(*) >= 5
)
SELECT l.cik, l.ticker, l.index_name, l.gics_sector, l.gics_sub_industry,
       l.peer_level, l.peer_group, l.concept, l.fact_type,
       l.value_date, l.tradable_from, l.days_stale, l.value,
       p.peer_count, p.peer_mean, p.peer_stddev, p.peer_min, p.peer_max,
       CASE WHEN p.peer_stddev IS NULL OR p.peer_stddev = 0 THEN NULL
            ELSE ((l.value - p.peer_mean) / p.peer_stddev)::NUMERIC(12,4) END AS zscore,
       ROUND(PERCENT_RANK() OVER (PARTITION BY l.concept, l.peer_level, l.peer_group
                                  ORDER BY l.value)::NUMERIC, 4) AS peer_percentile
FROM levelled l
JOIN moments  p USING (concept, peer_level, peer_group);
$$;

COMMENT ON FUNCTION sec_gold.peer_stats_asof(TEXT, DATE, INTEGER, INTEGER) IS
    'Peer cross-section of an index''s constituents as it was knowable on '
    'p_asof: latest annual flows and latest balance sheet actionable by '
    'that date (first disclosure, from fact_asof), ratios and growth on '
    'the same basis, membership and GICS as of the date, peer moments '
    'over what was knowable. days_stale per row; figures older than '
    'p_max_age_days are left out. Computed on demand; nothing is stored.';
