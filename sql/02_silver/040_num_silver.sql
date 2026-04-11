-- Master numeric fact table with dual ranking.
--
-- rank_pit   — "when did we first see this value" (backtesting, no look-ahead)
-- rank_latest — "most recent restatement of this value" (fundamental analysis)
--
-- Partition includes coreg and segments so restatements at the entity
-- level are ranked independently from subsidiary/segment filings.
CREATE TABLE sec_silver.num_silver AS
WITH raw_typed AS (
    SELECT
        n.adsh,
        s.cik,
        n.tag,
        n.version,
        n.ddate::DATE                                AS value_date,
        n.qtrs::INTEGER                              AS qtrs,
        n.uom,
        n.coreg,
        NULLIF(n.segments, '')                       AS segments,
        CASE
            WHEN n.value ~ '^[0-9\.\-]+$' THEN n.value::NUMERIC
            ELSE NULL
        END                                          AS value,
        n.footnote,
        s.filed_date,
        s.form
    FROM sec_raw.num_raw n
    JOIN sec_silver.sub_silver s ON n.adsh = s.adsh
)
SELECT
    r.adsh,
    r.cik,
    r.tag,
    r.version,
    t.tlabel,
    r.value_date,
    r.qtrs,
    r.uom,
    r.coreg,
    r.segments,
    r.value,
    r.footnote,
    r.filed_date,
    r.form,
    ROW_NUMBER() OVER (
        PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
        ORDER BY r.filed_date ASC, r.adsh ASC
    ) AS rank_pit,
    ROW_NUMBER() OVER (
        PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
        ORDER BY r.filed_date DESC, r.adsh DESC
    ) AS rank_latest
FROM raw_typed r
LEFT JOIN sec_silver.tag_silver t
    ON r.tag = t.tag AND r.version = t.version;

CREATE INDEX idx_num_cik_tag      ON sec_silver.num_silver (cik, tag);
CREATE INDEX idx_num_rank_pit     ON sec_silver.num_silver (rank_pit);
CREATE INDEX idx_num_rank_latest  ON sec_silver.num_silver (rank_latest);
