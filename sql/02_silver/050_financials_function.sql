-- Single entry point replacing the old view_financials_pit and
-- view_financials_latest. The segments/coreg "consolidated only"
-- filter lives here exclusively; nothing downstream re-applies it.
--
-- Usage:
--   SELECT * FROM sec_silver.financials('pit')    WHERE cik = 320193;
--   SELECT * FROM sec_silver.financials('latest') WHERE cik = 320193;
CREATE OR REPLACE FUNCTION sec_silver.financials(p_mode TEXT DEFAULT 'pit')
RETURNS TABLE (
    cik         INTEGER,
    tag         TEXT,
    tlabel      TEXT,
    metric      TEXT,
    value_date  DATE,
    qtrs        INTEGER,
    uom         TEXT,
    value       NUMERIC,
    filed_date  DATE,
    adsh        TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        n.cik,
        n.tag,
        n.tlabel,
        n.tlabel AS metric,
        n.value_date,
        n.qtrs,
        n.uom,
        n.value,
        n.filed_date,
        n.adsh
    FROM sec_silver.num_silver n
    WHERE n.segments IS NULL
      AND n.coreg IS NULL
      AND (
          (p_mode = 'pit'    AND n.rank_pit    = 1)
       OR (p_mode = 'latest' AND n.rank_latest = 1)
      );
$$;
