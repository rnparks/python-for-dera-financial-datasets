# SEC Financial Dataset Field Definitions

> Complete reference guide for all fields in the SEC Financial Statement Data Sets

> **Upstream SEC reference material.** This document describes the format SEC
> publishes, **not** the schema this project stores. It does not change when the
> pipeline changes. For what the pipeline actually holds — including the fields
> silver renames, such as `accepted` → `known_at` and `ddate` → `value_date` —
> see [`schema_overview.md`](schema_overview.md).


[![SEC](https://img.shields.io/badge/SEC-EDGAR-blue)](https://www.sec.gov/edgar)
[![Data Format](https://img.shields.io/badge/Format-XBRL-green)](https://www.sec.gov/data-research/standard-taxonomies)

## 📋 Table of Contents

- [Overview](#overview)
- [Dataset Structure](#dataset-structure)
- [SUB Dataset - Submission Data](#sub-dataset-submission-data)
  - [Identification Fields](#identification-fields)
  - [Business Classification](#business-classification)
  - [Business Address Fields](#business-address-fields)
  - [Mailing Address Fields](#mailing-address-fields)
  - [Incorporation Information](#incorporation-information)
  - [Name History](#name-history)
  - [Filer Status](#filer-status)
  - [Fiscal Period Information](#fiscal-period-information)
  - [Filing Dates](#filing-dates)
  - [Filing Metadata](#filing-metadata)
  - [Co-Registrant Information](#co-registrant-information)
- [TAG Dataset - Tag Definitions](#tag-dataset-tag-definitions)
- [NUM Dataset - Numeric Data](#num-dataset-numeric-data)
- [PRE Dataset - Presentation](#pre-dataset-presentation)
- [Dataset Relationships](#dataset-relationships)
- [Important Notes](#important-notes)
- [Resources](#resources)

---

## Overview

The SEC Financial Statement Data Sets provide XBRL-tagged financial information from public company filings in a flattened, analysis-ready format. The data includes quarterly and annual financial statements filed with the Commission since April 15, 2009.

**Four Main Datasets:**
- **SUB** - Submission-level information
- **TAG** - Tag definitions (data elements)
- **NUM** - Numeric facts from financial statements
- **PRE** - Presentation/rendering information

---

## Dataset Structure

```
SUB (Submissions)
 └─ adsh (primary key)
    ├─ NUM (Numbers)
    │   └─ adsh + tag + version + ddate + qtrs + uom + segments + coreg (composite key)
    │       └─ TAG (Tags)
    │           └─ tag + version (composite key)
    └─ PRE (Presentation)
        └─ adsh + report + line (composite key)
            └─ TAG (Tags)
                └─ tag + version (composite key)
```

---

## SUB Dataset (Submission Data)

> Contains summary information about each EDGAR submission. One record per XBRL submission.

### Identification Fields

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `adsh` | Accession Number | `nnnnnnnnnn-nn-nnnnnn` (20 char) | 20-character string formed from the 18-digit number assigned by SEC to each EDGAR submission | 🔑 **Primary Key** - Unique identifier for each filing |
| `cik` | Central Index Key | Numeric (10 digits) | Ten digit number assigned by SEC to each registrant | Unique identifier for each company/registrant that files with SEC |
| `name` | Name of Registrant | Alphanumeric (150 char) | Legal entity name as recorded in EDGAR at filing date | Identifies the company making the filing |

### Business Classification

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `sic` | Standard Industrial Classification | Numeric (4 digits) | Four digit code assigned by SEC indicating registrant's type of business | Categorizes companies by industry sector |

### Business Address Fields

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `countryba` | Country of Business Address | ISO 3166-1 (2 char) | ISO country code of registrant's business address | Location of company's principal business office |
| `stprba` | State/Province of Business Address | Alphanumeric (2 char) | State or province (if countryba is US or CA) | State/province location of business address |
| `cityba` | City of Business Address | Alphanumeric (30 char) | City of registrant's business address | City location of business address |
| `zipba` | Zip Code of Business Address | Alphanumeric (10 char) | Zip code of registrant's business address | Postal code of business address |
| `bas1` | Business Address Street Line 1 | Alphanumeric (40 char) | First line of street address | First line of business street address |
| `bas2` | Business Address Street Line 2 | Alphanumeric (40 char) | Second line of street address | Second line of business street address |
| `baph` | Business Address Phone | Alphanumeric (20 char) | Phone number of business address | Contact phone number for business address |

### Mailing Address Fields

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `countryma` | Country of Mailing Address | ISO 3166-1 (2 char) | ISO country code of registrant's mailing address | Country of company's mailing address |
| `stprma` | State/Province of Mailing Address | Alphanumeric (2 char) | State or province (if countryma is US or CA) | State/province of mailing address |
| `cityma` | City of Mailing Address | Alphanumeric (30 char) | City of registrant's mailing address | City of mailing address |
| `zipma` | Zip Code of Mailing Address | Alphanumeric (10 char) | Zip code of registrant's mailing address | Postal code of mailing address |
| `mas1` | Mailing Address Street Line 1 | Alphanumeric (40 char) | First line of street address | First line of mailing street address |
| `mas2` | Mailing Address Street Line 2 | Alphanumeric (40 char) | Second line of street address | Second line of mailing street address |

### Incorporation Information

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `countryinc` | Country of Incorporation | ISO 3166-1 (3 char) | ISO country code where registrant is incorporated | Identifies where company is legally incorporated |
| `stprinc` | State/Province of Incorporation | Alphanumeric (2 char) | State or province (if countryinc is US or CA) | State/province where company is incorporated |
| `ein` | Employer Identification Number | Numeric (9 digits) | IRS business identification number | Federal tax identification for US entities |

### Name History

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `former` | Former Name | Alphanumeric (150 char) | Most recent former name of registrant (if any) | Tracks company name changes |
| `changed` | Date of Name Change | Date `yyyymmdd` (8 char) | Date of change from former name (if any) | Records when name change occurred |

### Filer Status

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `afs` | Accelerated Filer Status | Alphanumeric (5 char) | Filer status at time of submission:<br>• `1-LAF` = Large Accelerated<br>• `2-ACC` = Accelerated<br>• `3-SRA` = Smaller Reporting Accelerated<br>• `4-NON` = Non-Accelerated<br>• `5-SML` = Smaller Reporting Filer<br>• `NULL` = not assigned | Indicates filing requirements and compliance deadlines |
| `wksi` | Well Known Seasoned Issuer | Boolean (1/0) | Flag indicating WKSI status | Indicates if issuer meets specific SEC requirements for expedited shelf registration |

### Fiscal Period Information

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `fye` | Fiscal Year End Date | `mmdd` (4 char) | Fiscal year end, rounded to nearest month-end | Identifies company's fiscal year end |
| `form` | Submission Type | Alphanumeric (10 char) | Type of filing (e.g., 10-K, 10-Q, 20-F, 40-F) | Categorizes the type of regulatory filing |
| `period` | Balance Sheet Date | Date `yyyymmdd` (8 char) | Reporting period end date, rounded to nearest month-end | Identifies the reporting period end date |
| `fy` | Fiscal Year Focus | Year `yyyy` (4 char) | Fiscal year covered by filing | Indicates which fiscal year the filing covers |
| `fp` | Fiscal Period Focus | `FY/Q1/Q2/Q3/Q4` (2 char) | Fiscal period within year | Indicates which fiscal period (annual or quarter) |

### Filing Dates

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `filed` | Filing Date | Date `yyyymmdd` (8 char) | Date filing was submitted to SEC | Date filing was submitted to SEC |
| `accepted` | Acceptance Date/Time | DateTime `yyyy-mm-dd hh:mm:ss` (19 char) | Exact timestamp when SEC accepted filing | Exact timestamp when SEC accepted the filing |

### Filing Metadata

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `prevrpt` | Previous Report Flag | Boolean (1/0) | TRUE if submission was subsequently amended | Indicates if submission was subsequently amended |
| `detail` | Detail Level Flag | Boolean (1/0) | TRUE if XBRL contains quantitative disclosures in footnotes at required detail level | Indicates level of XBRL detail provided |
| `instance` | Instance Document Name | Alphanumeric (40 char) | Filename of submitted XBRL instance document (e.g., `abcd-yyyymmdd.xml`) | Identifies the specific XBRL file submitted |

### Co-Registrant Information

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `nciks` | Number of CIKs | Numeric (4 digits) | Count of CIKs included in consolidated filing | Indicates how many business units are in the consolidated entity |
| `aciks` | Additional CIKs | Alphanumeric (120 char) | Space-delimited list of co-registrant CIKs (NULL if nciks=1) | Lists all additional entities included in consolidating filing |

---

## TAG Dataset (Tag Definitions)

> Contains information about all standard and custom XBRL tags used in submissions.

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `tag` | Tag Name | Alphanumeric (256 char) | Unique identifier/name for tag in specific taxonomy | 🔑 **Primary Key** - Primary identifier for the data element |
| `version` | Taxonomy Version | Alphanumeric (20 char) | For standard tags: taxonomy identifier<br>For custom tags: accession number where tag was defined | 🔑 **Primary Key** - Indicates source taxonomy or filing where tag originated |
| `custom` | Custom Tag Flag | Boolean (1/0) | `1` if custom (version=adsh)<br>`0` if standard | Distinguishes company-specific tags from standard taxonomy tags |
| `abstract` | Abstract Tag Flag | Boolean (1/0) | `1` if tag is not used to represent a numeric fact<br>`0` if concrete/numeric | Indicates if tag is used for organization/headers (not numeric facts) |
| `datatype` | Data Type | Alphanumeric (20 char) | Type of data (e.g., "monetary", "shares", "pure")<br>NULL if abstract=1 | Defines the nature of values this tag can hold |
| `iord` | Instant or Duration | `I` or `D` (1 char) | `I` = instant/point-in-time<br>`D` = duration/period<br>NULL if abstract=1 | Indicates whether values represent a moment or period of time |
| `crdr` | Credit or Debit | `C` or `D` (1 char) | `C` = credit<br>`D` = debit<br>Only for monetary datatypes | Indicates natural accounting balance of the element |
| `tlabel` | Terse Label | Alphanumeric (512 char) | Short label text from taxonomy or provided by filer | Provides readable name for the tag |
| `doc` | Documentation | Text | Detailed definition/description of the tag from taxonomy or filer | Explains what the tag represents and how it should be used |

---

## NUM Dataset (Numeric Data)

> Contains all numeric XBRL facts from primary financial statements. One row per distinct data point.

### Key Fields (Composite Unique Identifier)

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `adsh` | Accession Number | Alphanumeric (20 char) | EDGAR accession number | 🔑 Links numeric fact to specific filing |
| `tag` | Tag Name | Alphanumeric (256 char) | Unique identifier for taxonomy tag | 🔑 Identifies what data element this fact represents |
| `version` | Taxonomy Version | Alphanumeric (20 char) | Taxonomy identifier or accession number for custom tags | 🔑 Specifies tag definition source |
| `ddate` | Data Date | Date `yyyymmdd` (8 char) | End date for data value, rounded to nearest month-end | 🔑 Identifies reporting period end |
| `qtrs` | Quarters | Numeric (8 digits) | Count of quarters represented<br>• `0` = point-in-time<br>• `1` = one quarter<br>• `4` = annual/year-to-date | 🔑 Indicates duration of reporting period |
| `uom` | Unit of Measure | Alphanumeric (20 char) | Unit for the value (e.g., "USD", "shares", "pure") | 🔑 Specifies measurement unit |
| `segments` | XBRL Segments | Alphanumeric (1024 char) | Tags representing axis and member reporting (dimensional data) | 🔑 Captures breakdown by segment, geography, product line, etc. |
| `coreg` | Co-Registrant | Alphanumeric (256 char) | Identifier for specific co-registrant or entity<br>NULL = consolidated entity | 🔑 Distinguishes parent vs subsidiary data |

### Value Fields

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `value` | Numeric Value | Numeric (28,4) | The actual data value, not scaled, limited to 4 decimal places | Contains the reported financial amount |
| `footnote` | Footnote Text | Alphanumeric (512 char) | Text of superscripted footnotes on the value, truncated to 512 characters | Captures additional context or explanations for the value |

---

## PRE Dataset (Presentation)

> Shows how tags and numbers were presented in the financial statements. One row per line item on statements.

### Key Fields (Composite Unique Identifier)

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `adsh` | Accession Number | Alphanumeric (20 char) | EDGAR accession number | 🔑 Links presentation to specific filing |
| `report` | Report Number | Numeric (6 digits) | Numeric identifier for report grouping | 🔑 Groups related statement lines together |
| `line` | Line Number | Numeric (6 digits) | Sequential number for line within report | 🔑 Orders line items within statement |

### Presentation Information

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `stmt` | Statement Type | Alphanumeric (2 char) | Financial statement location:<br>• `BS` = Balance Sheet<br>• `IS` = Income Statement<br>• `CF` = Cash Flow<br>• `EQ` = Equity<br>• `CI` = Comprehensive Income<br>• `SI` = Schedule of Investments<br>• `UN` = Unclassifiable Statement | Categorizes which financial statement contains this line |
| `inpth` | In Parenthetical | Boolean (1/0) | `1` if value shown parenthetically<br>`0` if in columns | Indicates if value was shown parenthetically rather than in columns |
| `rfile` | Rendering File Type | `H` or `X` (1 char) | `H` = .htm file<br>`X` = .xml file | Indicates format of rendered file on EDGAR website |

### Tag Information

| Field | Name | Format | Description | Purpose |
|-------|------|--------|-------------|---------|
| `tag` | Tag Name | Alphanumeric (256 char) | Tag chosen by filer for this line item | Links presentation line to tag definition |
| `version` | Taxonomy Version | Alphanumeric (20 char) | Taxonomy identifier for standard tags, or adsh for custom | Identifies source of tag definition |
| `plabel` | Preferred Label | Alphanumeric (512 char) | Text presented on the line item in financial statement | Shows how filer labeled this item for users |
| `negating` | Negating Flag | Boolean (1/0) | `1` if label indicates value should be treated as negative<br>`0` otherwise | Indicates if value represents expenses, deductions, or other negative items |

---

## Dataset Relationships

Understanding how the datasets connect is crucial for analysis:

```
┌─────────────────┐
│   SUB (adsh)    │ ← Primary submission information
└────────┬────────┘
         │
    ┌────┴────┬──────────────┬─────────────┐
    ↓         ↓              ↓             ↓
┌───────┐ ┌───────┐     ┌──────┐      ┌──────┐
│  NUM  │ │  PRE  │     │ TAG  │      │ TAG  │
└───┬───┘ └───┬───┘     └──────┘      └──────┘
    │         │             ↑             ↑
    └─────────┴─────────────┴─────────────┘
         (tag + version keys)
```

### Join Operations

**Get numeric facts with submission details:**
```sql
SELECT * FROM NUM 
JOIN SUB ON NUM.adsh = SUB.adsh
```

**Get numeric facts with tag definitions:**
```sql
SELECT * FROM NUM
JOIN TAG ON NUM.tag = TAG.tag AND NUM.version = TAG.version
```

**Get presentation with numeric values:**
```sql
SELECT * FROM PRE
JOIN NUM ON PRE.adsh = NUM.adsh 
    AND PRE.tag = NUM.tag 
    AND PRE.version = NUM.version
```

**Complete financial statement reconstruction:**
```sql
SELECT 
    s.name, s.form, s.period,
    p.stmt, p.line, p.plabel,
    n.value, n.uom, n.ddate, n.qtrs,
    t.tlabel, t.doc
FROM PRE p
JOIN SUB s ON p.adsh = s.adsh
JOIN NUM n ON p.adsh = n.adsh 
    AND p.tag = n.tag 
    AND p.version = n.version
JOIN TAG t ON n.tag = t.tag 
    AND n.version = t.version
WHERE s.cik = 'YOUR_CIK'
ORDER BY s.period DESC, p.stmt, p.line
```

---

## Important Notes

### Data Quality & Usage

⚠️ **Disclaimer:** These datasets contain "as filed" data extracted directly from registrant submissions. The SEC does not guarantee accuracy, as data comes from individual registrants and may contain errors introduced during filing or extraction.

### Key Characteristics

- **Coverage:** April 15, 2009 to present
- **Update Frequency:** Quarterly
- **File Format:** Tab-delimited text files (UTF-8, `\n` line endings)
- **Data Source:** XBRL-tagged submissions only
- **Scope:** Primary financial statements and related footnotes

### Important Considerations

1. **Not a substitute for filings:** Always review complete SEC filings before making investment decisions
2. **Multiple reporting periods:** Data includes both current and historical periods from each filing
3. **Amendments included:** Dataset includes amended filings (check `prevrpt` field)
4. **Standard vs Custom tags:** Mix of standard taxonomy tags and company-specific custom tags
5. **Metadata available:** Additional filing metadata available in complete EDGAR submissions

### Accessing Complete Filings

Full submission files are available at:
```
https://www.sec.gov/Archives/edgar/data/{cik}/{accession}/
```

Where:
- `{cik}` = the CIK value from SUB dataset
- `{accession}` = the adsh value with dashes removed

**Example:**
```python
# For adsh = "0000320193-22-000108"
cik = "320193"  # from SUB.cik
accession = "000032019322000108"  # adsh with dashes removed
url = f"https://www.sec.gov/Archives/edgar/data/{cik}/{accession}/"
```

---

## Resources

### Official SEC Resources

- 📄 [Financial Statement Data Sets](https://www.sec.gov/dera/data/financial-statement-data-sets.html)
- 📚 [SEC EDGAR](https://www.sec.gov/edgar)
- 🏷️ [Standard Taxonomies](https://www.sec.gov/data-research/standard-taxonomies)
- 📖 [EDGAR Filer Manual](https://www.sec.gov/info/edgar/edgarfm.htm)

### Data Access

- 💾 [Quarterly Data Files](https://www.sec.gov/data-research/sec-financial-data-sets)
- 🔍 [Company Search](https://www.sec.gov/edgar/searchedgar/companysearch.html)

### Related Documentation

- [XBRL US GAAP Taxonomy](https://xbrl.us/xbrl-taxonomy/2023-us-gaap/)
- [SEC Structured Disclosure](https://www.sec.gov/structureddata)

---

## Contributing

Found an error or have a suggestion? Please contribute:

1. Check existing issues
2. Open a new issue with detailed description
3. Submit pull requests with improvements

---

## License

This documentation is provided as-is for educational and research purposes. SEC data is public domain.

---

**Last Updated:** December 2024 (based on SEC Financial Statement Data Sets documentation)

**Version:** 1.0.0

