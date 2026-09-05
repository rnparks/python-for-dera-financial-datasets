-- Incremental silver: fold one bronze quarter into an existing silver
-- layer without rebuilding 185M rows.
--
-- `dera build-silver` is a CREATE TABLE AS over every quarter: ~39
-- minutes in one transaction, so a new DERA quarter (four a year) cost
-- the same as the first build and a late failure discarded everything.
-- sec_silver.build_quarter(p_quarter) does the same work for the rows
-- that quarter can change:
--
--   1. sub_silver gains the quarter's filings, typed and given their
--      tradable_from against the calendar, exactly as 020 does;
--   2. tag_silver gains any (tag, version) not seen before;
--   3. num_silver: the quarter's facts are typed as in 040, the set of
--      fact partitions they belong to -- (cik, tag, value_date, qtrs,
--      uom, coreg, segments) -- is collected, every existing silver row
--      of those partitions is pulled out, and the partitions are
--      recomputed in full from old rows plus new: vintage_seq,
--      superseded_known_at, superseded_tradable, rank_pit, rank_latest
--      are window functions over the partition and a new vintage moves
--      every older one, so recomputing the whole partition is the only
--      correct move. Untouched partitions are not read.
--
-- Idempotent and replacement-safe: the quarter's own filings are
-- excluded from the "old rows" set before the recompute, so running it
-- twice, or after `dera load --quarter Q --force`, yields exactly what a
-- full build would. Validated 2026-09-04 by re-folding 2026q2 (3.6M
-- facts, 3.4M partitions, 6.1M rows out and in) and recomputing 3,000
-- random touched partitions from bronze with 040's own SQL: every
-- column identical. 16:51 against the 39-minute full build; check 57
-- keeps the vintage columns honest on the newest quarter.
--
-- What it does NOT do: remove silver rows for a filing that a
-- re-published quarter no longer contains. DERA does not re-publish
-- quarters in practice; if one ever changes that way, the full build
-- is the clean path.
--
-- After it: `dera rebuild-reference`, which refills the spine (new
-- filers), rebuilds the security model and refreshes the gold matviews
-- whose inputs changed.

CREATE OR REPLACE PROCEDURE sec_silver.build_quarter(p_quarter TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_sub      BIGINT;
    v_tag      BIGINT;
    v_new      BIGINT;
    v_keys     BIGINT;
    v_old      BIGINT;
    v_deleted  BIGINT;
    v_inserted BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sec_raw.load_log WHERE quarter = p_quarter) THEN
        RAISE EXCEPTION 'quarter % is not in sec_raw.load_log; `dera load --quarter %` first',
            p_quarter, p_quarter;
    END IF;

    -- 1. Filings. Same typing and calendar resolution as 020_sub_silver.
    INSERT INTO sec_silver.sub_silver
        (adsh, cik, name, sic, countryba, stprba, cityba, zipba, bas1, form,
         period_date, fy, fp, fye, filed_date, known_at, was_amended_later,
         is_detailed, nciks, aciks, tradable_from)
    SELECT t.adsh, t.cik, t.name, t.sic, t.countryba, t.stprba, t.cityba, t.zipba, t.bas1, t.form,
           t.period_date, t.fy, t.fp, t.fye, t.filed_date, t.known_at, t.was_amended_later,
           t.is_detailed, t.nciks, t.aciks, cal.session_date
    FROM (
        SELECT adsh,
               cik::INTEGER                  AS cik,
               name,
               sic::INTEGER                  AS sic,
               countryba, stprba, cityba, zipba, bas1, form,
               period::DATE                  AS period_date,
               fy::INTEGER                   AS fy,
               fp, fye,
               filed::DATE                   AS filed_date,
               (accepted::TIMESTAMP AT TIME ZONE 'America/New_York') AS known_at,
               NULLIF(prevrpt, '')::BOOLEAN  AS was_amended_later,
               NULLIF(detail, '')::BOOLEAN   AS is_detailed,
               NULLIF(nciks, '')::INTEGER    AS nciks,
               aciks
        FROM sec_raw.sub_raw
        WHERE source_quarter = p_quarter AND adsh IS NOT NULL
    ) t
    LEFT JOIN LATERAL (
        SELECT c.session_date
        FROM sec_reference.trading_calendar c
        WHERE c.close_at > t.known_at
        ORDER BY c.close_at
        LIMIT 1
    ) cal ON TRUE
    ON CONFLICT (adsh) DO UPDATE SET
        cik = EXCLUDED.cik, name = EXCLUDED.name, sic = EXCLUDED.sic,
        countryba = EXCLUDED.countryba, stprba = EXCLUDED.stprba, cityba = EXCLUDED.cityba,
        zipba = EXCLUDED.zipba, bas1 = EXCLUDED.bas1, form = EXCLUDED.form,
        period_date = EXCLUDED.period_date, fy = EXCLUDED.fy, fp = EXCLUDED.fp, fye = EXCLUDED.fye,
        filed_date = EXCLUDED.filed_date, known_at = EXCLUDED.known_at,
        was_amended_later = EXCLUDED.was_amended_later, is_detailed = EXCLUDED.is_detailed,
        nciks = EXCLUDED.nciks, aciks = EXCLUDED.aciks, tradable_from = EXCLUDED.tradable_from;
    GET DIAGNOSTICS v_sub = ROW_COUNT;

    -- 2. Taxonomy rows first seen in this quarter.
    INSERT INTO sec_silver.tag_silver (tag, version, custom, abstract, datatype, tlabel, doc)
    SELECT DISTINCT ON (tag, version)
           tag, version, custom::BOOLEAN, abstract::BOOLEAN, datatype, tlabel, doc
    FROM sec_raw.tag_raw
    WHERE source_quarter = p_quarter
    ORDER BY tag, version
    ON CONFLICT (tag, version) DO NOTHING;
    GET DIAGNOSTICS v_tag = ROW_COUNT;

    -- 3a. The quarter's facts, typed as in 040_num_silver (same grammar,
    --     same join to sub_silver, same segments/coreg treatment).
    CREATE TEMP TABLE q_new ON COMMIT DROP AS
    SELECT n.adsh, s.cik, n.tag, n.version,
           n.ddate::DATE            AS value_date,
           n.qtrs::INTEGER          AS qtrs,
           n.uom, n.coreg,
           NULLIF(n.segments, '')   AS segments,
           CASE WHEN n.value ~ '^-?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$'
                THEN n.value::NUMERIC ELSE NULL END AS value,
           n.footnote, s.filed_date, s.known_at, s.tradable_from, s.form,
           (s.period_date - n.ddate::DATE) <= 100 AS is_original_disclosure
    FROM sec_raw.num_raw n
    JOIN sec_silver.sub_silver s ON s.adsh = n.adsh
    WHERE n.source_quarter = p_quarter;
    GET DIAGNOSTICS v_new = ROW_COUNT;

    CREATE TEMP TABLE q_adsh ON COMMIT DROP AS
    SELECT DISTINCT adsh FROM q_new;

    CREATE TEMP TABLE q_keys ON COMMIT DROP AS
    SELECT DISTINCT cik, tag, value_date, qtrs, uom, coreg, segments FROM q_new;
    GET DIAGNOSTICS v_keys = ROW_COUNT;
    ANALYZE q_keys;

    -- 3b. Existing rows of the touched partitions: ONE sequential pass over
    --     num_silver with a hash semi-join against the keys. Two other
    --     shapes were tried and abandoned on the same quarter: joining the
    --     3.4M seven-column keys straight to the table (the planner chose
    --     a merge join that sorts all 185M rows, or 60 GB sequential scans
    --     twice), and reaching the rows through the (cik, tag) index (33M
    --     random heap fetches; 15 minutes in, nothing had been found). A
    --     scan reads the 60 GB in order, the hash of the keys fits in
    --     work_mem, and the cost no longer depends on an estimate. The
    --     planner settings are pinned for this statement only, because the
    --     estimate it would otherwise trust is the one that misled it.
    --     Every touched row's ctid is kept so the DELETE is a tid join.
    SET LOCAL work_mem = '2GB';
    SET LOCAL enable_indexscan = off;
    SET LOCAL enable_indexonlyscan = off;
    SET LOCAL enable_bitmapscan = off;
    SET LOCAL enable_mergejoin = off;
    SET LOCAL enable_nestloop = off;

    CREATE TEMP TABLE q_touched ON COMMIT DROP AS
    SELECT n.ctid AS tid, n.adsh, n.cik, n.tag, n.version, n.value_date, n.qtrs, n.uom, n.coreg, n.segments,
           n.value, n.footnote, n.filed_date, n.known_at, n.tradable_from, n.form,
           n.is_original_disclosure
    FROM sec_silver.num_silver n
    WHERE EXISTS (SELECT 1 FROM q_keys k
                   WHERE k.cik = n.cik AND k.tag = n.tag AND k.value_date = n.value_date
                     AND k.qtrs = n.qtrs AND k.uom = n.uom
                     AND k.coreg    IS NOT DISTINCT FROM n.coreg
                     AND k.segments IS NOT DISTINCT FROM n.segments);
    GET DIAGNOSTICS v_old = ROW_COUNT;

    SET LOCAL enable_indexscan = on;
    SET LOCAL enable_indexonlyscan = on;
    SET LOCAL enable_bitmapscan = on;
    SET LOCAL enable_mergejoin = on;
    SET LOCAL enable_nestloop = on;

    -- 3c. Out with every row of the touched partitions (the quarter's
    --     own earlier rows included, so a re-run recomputes from the
    --     same inputs a full build would see) ...
    DELETE FROM sec_silver.num_silver n
    USING q_touched t
    WHERE n.ctid = t.tid;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    -- 3d. ... and in with the partitions recomputed whole. The window
    --     definitions are 040's, verbatim.
    INSERT INTO sec_silver.num_silver
        (adsh, cik, tag, version, tlabel, value_date, qtrs, uom, coreg, segments, value, footnote,
         filed_date, known_at, tradable_from, form, is_original_disclosure,
         vintage_seq, superseded_known_at, superseded_tradable, rank_pit, rank_latest)
    SELECT r.adsh, r.cik, r.tag, r.version, t.tlabel, r.value_date, r.qtrs, r.uom, r.coreg, r.segments,
           r.value, r.footnote, r.filed_date, r.known_at, r.tradable_from, r.form, r.is_original_disclosure,
           ROW_NUMBER() OVER w_asc,
           LEAD(r.known_at)      OVER w_asc,
           LEAD(r.tradable_from) OVER w_asc,
           ROW_NUMBER() OVER w_asc,
           (COUNT(*) OVER w_part - ROW_NUMBER() OVER w_asc + 1)::BIGINT
    FROM (
        SELECT adsh, cik, tag, version, value_date, qtrs, uom, coreg, segments, value, footnote,
               filed_date, known_at, tradable_from, form, is_original_disclosure
        FROM q_touched
        WHERE NOT EXISTS (SELECT 1 FROM q_adsh a WHERE a.adsh = q_touched.adsh)
        UNION ALL
        SELECT adsh, cik, tag, version, value_date, qtrs, uom, coreg, segments, value, footnote,
               filed_date, known_at, tradable_from, form, is_original_disclosure FROM q_new
    ) r
    LEFT JOIN sec_silver.tag_silver t ON t.tag = r.tag AND t.version = r.version
    WINDOW
        w_part AS (PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments),
        w_asc  AS (PARTITION BY r.cik, r.tag, r.value_date, r.qtrs, r.uom, r.coreg, r.segments
                   ORDER BY r.known_at ASC, r.adsh ASC);
    GET DIAGNOSTICS v_inserted = ROW_COUNT;

    ANALYZE sec_silver.sub_silver;
    ANALYZE sec_silver.num_silver;

    RAISE NOTICE 'build_quarter(%): % filings upserted, % taxonomy rows added, % facts in the quarter, % partitions touched, % rows out, % rows in',
        p_quarter, v_sub, v_tag, v_new, v_keys, v_deleted, v_inserted;
END;
$$;

COMMENT ON PROCEDURE sec_silver.build_quarter(TEXT) IS
    'Fold one loaded bronze quarter into silver: upsert its filings, add '
    'new taxonomy rows, and recompute every num_silver partition the '
    'quarter touches. Idempotent. Follow with dera rebuild-reference.';
