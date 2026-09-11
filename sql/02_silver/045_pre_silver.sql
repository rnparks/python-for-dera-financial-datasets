-- Presentation rows: how each filing laid out its statements.
--
-- DERA's pre.txt records every line of every rendered statement -- the
-- balance sheet, income statement, cash flow -- with the tag behind it
-- and the LABEL THE FILER PRINTED. num_silver holds the values; this
-- holds the shape: which lines a balance sheet has, in what order,
-- under what words. The gold layer reads the balance-sheet face from
-- it (03_gold/037_debt_face.sql) to decide, per filing, whether a
-- company presented any borrowing at all -- something no tag can say,
-- since a company with no debt files no debt tag.
--
-- Typed, never interpreted: report and line are the statement and row
-- numbers, inpth marks a parenthetical row, negating a label that
-- flips the sign. (adsh, report, line) is the row's identity. The
-- quarterly fold (060_incremental.sql) adds a new quarter's rows the
-- same way; a filing's presentation is never restated by a later one,
-- so there is nothing to recompute.

DROP TABLE IF EXISTS sec_silver.pre_silver;

CREATE TABLE sec_silver.pre_silver AS
SELECT DISTINCT ON (adsh, report::INTEGER, line::INTEGER)
       adsh,
       report::INTEGER              AS report,
       line::INTEGER                AS line,
       stmt,
       inpth = '1'                  AS inpth,
       rfile,
       tag,
       version,
       plabel,
       NULLIF(negating, '') = '1'   AS negating
FROM sec_raw.pre_raw
WHERE adsh IS NOT NULL AND report ~ '^[0-9]+$' AND line ~ '^[0-9]+$'
ORDER BY adsh, report::INTEGER, line::INTEGER;

ALTER TABLE sec_silver.pre_silver ADD PRIMARY KEY (adsh, report, line);
CREATE INDEX idx_pre_adsh_stmt ON sec_silver.pre_silver (adsh, stmt);

COMMENT ON TABLE sec_silver.pre_silver IS
    'One row per statement line of every filing, as rendered: statement '
    '(stmt: BS, IS, CF, ...), row order, the tag behind the line and the '
    'label the filer printed. The balance-sheet face read by '
    'sec_gold.debt_face.';
