-- XBRL taxonomy: one row per (tag, version).
CREATE TABLE sec_silver.tag_silver AS
SELECT DISTINCT ON (tag, version)
    tag,
    version,
    custom::BOOLEAN,
    abstract::BOOLEAN,
    datatype,
    tlabel,
    doc
FROM sec_raw.tag_raw
ORDER BY tag, version;

ALTER TABLE sec_silver.tag_silver ADD PRIMARY KEY (tag, version);
