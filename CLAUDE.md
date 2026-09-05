# Working agreements for this repository

## Documentation must never go stale

**Every change updates its documentation in the same commit.** This is not a
nice-to-have here: the docs once drifted ten commits behind in two days, ending
with `README.md` and `docs/architecture.md` containing zero mentions of
`sec_gold.fact_asof`, `sec_reference` or the point-in-time layer — the whole
purpose of the project — and `docs/gold_tables.md` contradicting itself inside
one document. A confidently wrong doc is worse than no doc.

### What to update, by what you changed

| If you changed… | Update |
|---|---|
| A CLI command or flag | `README.md`, the `cli.py` module docstring |
| A table, matview or column | `docs/schema_overview.md`, `docs/gold_tables.md` if in `sec_gold` |
| A function signature or default | `docs/gold_tables.md` (it documents every signature) |
| Where data comes from | `docs/data_sources.md`, including its provenance gaps section |
| Layer design or build ordering | `docs/architecture.md` |
| Anything shipped or newly blocked | `features.md` — status snapshot **and** the Shipped list |
| A SQL file's location or purpose | its own header, and `docs/gold_tables.md`'s source-files table |
| The crosswalk, index history, spine or security derivation | `docs/data_sources.md` (capture quality, rules), then `dera rebuild-reference` |
| A share-class mapping | `data/reference/share_class_map.csv` with a cited source_note; prefer `tools/fetch_cover_page_classes.py` |
| A pure Python function | `tests/test_pure_functions.py` |

### Before committing

```bash
uv run dera verify-docs    # object names (prose and SQL), paths, CLI commands, cross-links
uv run dera verify         # 56 data-correctness checks
uv run pytest              # unit tests, no database
uv run ruff check .        # what CI runs
```

`verify-docs` is **necessary, not sufficient**. It deliberately checks only
mechanically verifiable things; it cannot tell you that a paragraph now describes
behaviour you just changed. Re-read the prose you touched.

Volatile numbers are **date-stamped**, not generated — each doc carrying
measurements says "as of YYYY-MM-DD". If you refresh a number, move the stamp.

Use `check-docs:ignore` on a line only for deliberate references to things that
do not exist: roadmap proposals, or historical names quoted verbatim.

## Conventions worth not re-deriving

- **Measure, don't assert.** Claims that shape a decision get verified against
  the database or the code first. Query the table, not `reltuples` — that is a
  planner estimate and it has been wrong here by 2 rows out of 70.
- **Availability, not filing date.** Anything point-in-time keys on
  `tradable_from`, never `filed_date`. 57% of filings are accepted after the
  close and carry that day's `filed_date`.
- **Allowlist, don't pattern-match.** Where a wrong answer is possible, prefer a
  design that produces *nothing* over one that produces something plausible —
  `sec_reference.share_class` is the worked example.
- **Enforce structurally.** Invariants belong in CHECK constraints, not
  conventions. The `sec_reference.eligibility` constraints caught a real defect
  the first time they met production data.
- **No default knowledge date.** The `as_of_*` family requires one, so a
  look-ahead has to be written on purpose.
- Never force-push; always new commits.
