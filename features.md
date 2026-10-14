# DERA Research Platform — Feature Roadmap

A living document that tracks what exists, what's partial, and what's planned. The goal: any future session can pick an item and execute it without re-deriving context.

**Last updated**: 2026-10-12
**Branch**: `main` (work lands via short-lived branches such as `review-fixes`)
**Maintainer**: Ryan Parks

---

## Status snapshot

Postgres medallion pipeline (`sec_raw` → `sec_silver` → `sec_gold` →
`sec_reference`) over SEC DERA Financial Statement Data Sets,
2009q1 → 2026q3, 189M num rows, 164 GB (2026-10-12).

**All figures in this file are as of 2026-09-04 unless dated otherwise.**

**Usable today**:
- Bronze/silver/gold end-to-end. `run-all` no longer destroys a populated bronze; that needs `--reinit-bronze`. Every bronze row carries `source_quarter`, so `dera load --quarter Q --force` replaces a quarter in place; without `--force` a loaded quarter is refused, and `--full` still requires `--truncate`.
- **A new quarter is a fold, not a rebuild.** `dera build-silver --quarter Q` calls `sec_silver.build_quarter`: the quarter's filings are upserted, new taxonomy rows added, and every `num_silver` fact partition the quarter touches is recomputed whole from old rows plus new, so vintage, supersession and rank columns come out exactly as a full build would (check 57; 3,000 random touched partitions recomputed from bronze with the full build's SQL matched on every column). Untouched partitions are never read. Measured on 2026q2: 16:51 against the 39-minute full build. Then `dera rebuild-reference` refills the spine and refreshes the gold matviews whose inputs changed. **Rehearsed end to end on 2026-09-10** (2026q2 reloaded under `--force`, folded, `rebuild-reference --refresh-all`): 1:16 + 17:48 + 26:34, the same 6,055,685 rows out and in, every silver, reference and gold row count identical afterwards, 60/60. The one open question from 2026-09-05, a refresh that left `tradable_financials` at 1,701 companies when the next gave 2,392, did not reproduce and is explained: that refresh ran before the S&P 400 and 600 histories were fetched (files stamped 22:23 and 22:30; the bronze reload 21:42), and 1,701 is the S&P 500-only population check 41 records growing to 2,392 when they landed.
- **Bitemporal point-in-time correctness.** `sec_gold.fact_asof` keeps every vintage of every fact with `known_at`, `tradable_from` and `superseded_tradable`. An as-of slice is an indexed interval scan returning exactly one row per fact. Verified on GE fiscal 2022 revenue, which has **four** vintages, not two: $76.555B as first filed 2023-02-10, restated to $58.100B by an 8-K on 2023-04-25, reaffirmed 2024-02-02, then $29.139B on 2025-02-03.
- **Availability, not filing date.** `tradable_from` is derived from the EDGAR acceptance timestamp against a real NYSE calendar. 57% of filings (247,216 of 433,717) are accepted after the close; 48% of all filings (209,441) still carry that day's `filed_date`. 433 filings are actionable *before* their `filed_date` (accepted after 5:30 pm on the eve of a federal holiday NYSE trades through). `docs/data_sources.md` has the full breakdown.
- **As-of accessors** where the knowledge date has no default, so omitting it is an error rather than a silent leak: `as_of_facts`, `as_of_canonical`, `as_of_latest_annual`, `as_of_snapshot` (by CIK or by ticker). `p_buffer_sessions` applies a safety margin in trading sessions. The silent-empty paths are gone: `financials('asof')` without a date, `shift_sessions` before the calendar, and a ticker the crosswalk cannot resolve on the date all **raise**.
- **Derived concepts resolve everywhere.** `concept_formula` computes `gross_profit`, `free_cash_flow` and `total_debt`; both `latest_annual` and `as_of_latest_annual` fall back to it and the newest period wins over a stale direct tag. `total_debt` resolves for 1,133 of 1,133 tracked companies that `peer_stats` scores for FY2024 (was 256 before the formula, 1,063 before the 2026-09-04 tag additions); Apple's snapshot reads $82.7B at 2026-03-31, not $40.1B at 2015-03-31.
- **Gross profit in taxonomy order.** `cost_of_revenue` walks the total (`CostOfRevenue`) before its child, and goods/services component filers resolve through guarded formula variants. Measured 2026-10-01 (`docs/audits/gross_profit.md`): agreement with a filed gross profit 96.1% for the total (95.3% in the old order); the guarded component variants add 2,134 non-financial annual periods with no filed gross profit; `get_canonical` matches the audit's independent evaluation in all 51,905 periods (the 7 earlier differences were the audit's own per-filing SIC filter: two companies changed SIC between filings). Single-step filers stay NULL by design (`docs/gold_tables.md`, coverage ceilings). The as-of side caught up on 2026-10-12, when the committed `as_of_canonical` and `peer_stats` were first deployed (they had kept the year-end balance guard): 261 of 18,060 as-of company-years moved, 200 guarded values to NULL (Oracle FY2018's 36.5B) and 61 that a balance-sheet custom line had wrongly blocked now resolving, every one now equal to `get_canonical(..., 'latest')`; `peer_stats` lost 304 and gained 71 gross-profit rows (as many gross-margin rows), and no surviving row's own value moved.
- **Revenue before ASC 606.** `SalesRevenueNet` and its siblings are mapped; FY2015 revenue covers 1,283 of 1,361 tracked issuers (was 628), FY2010 1,105 (was 552).
- **Survivorship-free company spine.** `sec_reference.company` holds every CIK that ever filed; `company_ticker` gives dated ticker intervals with `is_primary`, built from **81 monthly archive captures** (2018-12 to 2026-09) of SEC's ticker file. 12,321 of 20,326 CIKs with an interval are absent from SEC's live file. A capture is evidence of presence, never proof of absence on its own: 18 undersized captures are flagged in `sec_reference.ticker_capture` and short silences are bridged. A company that has only ever had one primary ticker is extended back to its first filing (`source = 'extended'`, 6,405 CIKs), and every as-of flag downstream is true for observed intervals only.
- **Security lifecycle model — 17,025 listed securities.** `sec_reference.{security,listing,eligibility,delisting_event,corporate_action,company_name}` separate a company from the securities it issues, built from 905,049 EDGAR filing events across 17,015 CIKs. Form types are matched whole (a prefix match once read Regulation A circulars as Form 25). 7,119 outcomes: 4,498 exchange notices, 2,621 deregistrations (companies that went dark without a Form 25 and had no outcome row before). `universe_at('filers_10k_15m','2015-06-30')` returns **7,293 members, 3,012 of them (41%) since delisted or deregistered** — a current-constituents universe returns none.
- **Multi-class market cap denominator, decided from the filings.** A single-class issuer is one that has never reported share counts for two `ClassOfStock` members, so preferreds, baby bonds and delistings no longer exclude anyone (Bank of America with seventeen tickers is single-class) and dual-class issuers with an unlisted second class (Meta, Nike, Visa) are no longer priced on an unverified 1:1. Dual-class issuers need a cited mapping: `tools/fetch_cover_page_classes.py` derives it from the issuer's own 10-K cover page, and 57 S&P 500 issuers are mapped that way alongside the 9 by hand (99 rows, every one citing its filing). 482 of today's 500 constituents have per-class counts; the denominator covers 9,654 companies overall. `share_classes_at(cik, asof)` returns one row per class with `price_ticker_is_asof`.
- **CIK succession.** `sec_reference.cik_succession` (223 ticker handoffs between registrants, from SEC's own file) lets the spine cut a membership interval at a holding-company reorganisation: Apache's S&P 500 years are keyed to 6769 and APA Corp's to 1841666, Cigna's and WestRock's to the registrant that was filing. Five S&P 500 constituents of 2020-06-30 had no filer behind their CIK before; none remains but First Republic, which reported to the FDIC. Closed on 2026-09-11: (1) the page's "date added" belongs to the seat and survives a ticker change at succession, so Paramount Skydance (PSKY, first filing 2024-11-04) had been a member from CBS's 1994-09-30 alongside Paramount Global — no interval now starts before the first EDGAR filing of the registrant it will hold (PSKY, Walgreens Boots Alliance, Linde plc, Viatris, Kraft Heinz, WestRock, Perrigo plc moved); (2) a successor's interval that ended before the handoff was never re-keyed, and SEC's file dates a handoff by when it dropped the old CIK, so Alphabet was the member from 2008 and Google Inc never — such an interval is now cut at the successor's first EDGAR filing (Google Inc to 2015-10-02, the day of the reorganisation; 27 intervals, Disney, Xerox, Cigna, BlackRock, Apache among them); (3) a successor with no filing in DERA yet was no succession, so from the day the crosswalk moved XOM to ExxonMobil Holdings (2026-07-16) Exxon's whole history sat under a CIK with no facts and Exxon was in no S&P 500 panel — 34088 holds 2008 to 2026-07-16 again. 22 intervals over 16 seats still name a successor from its first capture (successions before the file's reach: Mylan N.V., Medtronic plc, Perrigo plc), pinned so the count can only fall. Check 59.
- **All three indexes replayed, with the 600's page read for what it was.** `fetch_sp500_history.py --index SP400|SP600` replays the S&P 400 (153 captures since 2011, no CIK column: SEC's dated crosswalk resolves 92% of its sightings) and the S&P 600 (92 captures since 2018). The early S&P 600 page was the S&P 1000 — 994 rows, 395 of them on the same month's S&P 400 page — so the spine subtracts that page and keeps a capture only when about 600 rows remain; where the pages drifted apart (2019-12 to 2021-02) only the 444 members seen on both sides survive, an honest hole rather than a 75%-right list. A run's CIK now comes from the page only when SEC's crosswalk does not disagree, which retired that page's trailing-zero CIKs (73320 for 7332), and membership runs are GICS-blind with GICS segmented inside them, which closed the gaps a classification change used to open. S&P 400 390–400 members on every mid-year date, S&P 600 596–600 outside the hole, S&P 500 500–505 (was up to 517). No `current_snapshot` rows remain.
- **Constituent runs resolve by dated name, allowlist or neighbour** (2026-09-11). A run the page and the crosswalk cannot key is matched on every name the page gave it against the names the company bore *at the time* (EDGAR's dated former names, the current name, DERA filing names) and the EDGAR filing span rather than DERA's XBRL start; `data/reference/index_cik_overrides.csv` (8 cited rows) settles what a name cannot; a run split from its neighbour only by partial captures takes the neighbour's CIK. 36 tickers unresolved, down from 138, none a company with facts in DERA. Sunoco, Kraft Foods, Viacom and Qwest are S&P 500 members for their years, New York Community Bancorp an S&P 400 member for its eleven; the S&P 600 of 2018-09-15 has 589 members, not 507, the S&P 500 of 2009-06-30 496, not 489. Six resolutions dropped: a page error (a mangled AMB row had put AMC Networks in the S&P 400 from 2011), four ghost rows and a one-capture ambiguity. Check 61.
- **Dated S&P 500 membership, and gold reads it.** `sec_reference.index_membership` is replayed from 214 monthly Wikipedia captures since 2008 (841 companies ever in the index against 503 today; 25 pre-2010 tickers unresolved and listed, none with facts in DERA), with GICS as of the interval. The two `tradable_financials` matviews carry `index_name`, `index_is_asof` and as-of GICS per fact, and `peer_stats` scores only facts whose company was a constituent when the fact became actionable, so a FY2012 cross-section is 2012's index. `universe_at('sp500', date)` (508 securities on 2015-06-30) and `index_members('SP500', date)` expose it; the FY2012 peer panel holds 476 S&P 500 companies, FY2024 499. The S&P 400 and 600 followed on 2026-09-05.
- **Peer stats at two GICS levels** in one table tagged by `peer_level`, with `index_name` on every row.
- **A knowledge-date peer cross-section, computed on demand.** `sec_gold.peer_stats_asof(index, T)` returns every constituent of an index on date T with the latest annual flows and latest balance sheet that were actionable by T (first disclosure, from `fact_asof`), the ratio and growth concepts on the same basis, membership and GICS as of T, and peer moments and percentiles over what was knowable then; `days_stale` is a column and figures older than 550 days (configurable) are left out. It is a function, not a table: the S&P 500 takes about 13 seconds a call and nothing is stored. Apple's FY2024 revenue is in the 2024-11-15 cross-section and not the 2024-10-15 one (check 56).
- **Operating cash flow resolves for the continuing-operations filers.** `NetCashProvidedByUsedInOperatingActivitiesContinuingOperations` is what 3,944 companies file instead of the plain tag (27,213 filings; Apple's FY2014 and FY2015 10-Ks among them), and until 2026-09-05 nothing mapped it, so their free cash flow, FCF margin and OCF growth were missing or resolved to a stale year. Mapped at priority 2; `gold_tables.md` now states the rule for each tag-name family. Check 60.
- **Margins, returns, leverage and growth, with peer scores.** `sec_gold.concept_ratio` defines 11 scale-free concepts (gross/operating/net/FCF margin, ROE, ROA, debt-to-equity, and year-over-year growth of revenue, net income, diluted EPS and operating cash flow) as ratios of concepts at one period or of one concept over its prior fiscal year. A non-positive denominator or base is NULL, never a number. `peer_stats` scores them with the same moments and percentiles as the dollar concepts (FY2024: net margin for 1,438 companies, revenue growth 1,397); `latest_annual`, `as_of_latest_annual` and both snapshots resolve them, so the 26-concept snapshot works as of any date. Check 55 pins Apple, NVIDIA and a Boeing NULL.
- **A strict filer universe.** `filers_10k_15m_strict` is `filers_10k_15m` with one change: a security whose first trade is known only from its first periodic report enters at its first 424B1/424B4 pricing when one exists later (1,832 intervals; 7,082 members on 2015-06-30 against 7,298, 6,837 against 6,868 in 2024). Every strict interval lies inside a base interval and never before the pricing (check 54); Plymouth Industrial REIT is the named case, reporting from 2011 and priced 2017-06-09.
- **Cross-section balances are fiscal year-end balances.** A `peer_stats` balance row is admitted only on a date the company also reports an annual period for; before this, 91% of FY2024 balance rows (6,739 of 7,378) were Q1 10-Q balances because `fiscal_year_of` puts a March period end in the prior year and the latest date won. JPMorgan's FY2024 debt is now the 2024-12-31 figure (401B), Apple's FY2024 assets the September one. Two companies without a FY2024 10-K (Marathon Oil, BlackRock's old registrant) drop out of FY2024 rather than showing a quarter's balance.
- **Quarterly flows and trailing twelve months, computed on demand** (2026-09-11). `sec_gold.as_of_quarterly(cik, asof)` returns every fiscal quarter of every flow concept as it was knowable on a date: the quarter (the filed three-month figure, else the difference of two year-to-date figures, since the 10-K never carries a fourth quarter and 10-Q cash flows come year-to-date only), the trailing twelve months (the annual figure at a fiscal year-end, else prior year + year-to-date − the prior year's year-to-date, else four quarters summed), and growth quarter-over-quarter, year-over-year and against the prior trailing year, NULL from a non-positive base. `as_of_trailing` is the newest quarter per concept, by CIK or by ticker; `quarterly` and `trailing` the same as of today. **Nothing is stored** — the database gains no rows — and a company takes about 60 ms, an S&P 500 cross-section 16 s. Apple's quarter to 2024-06-30 reads 85.777B revenue, 28.858B operating cash flow (91.443 − 62.585) and 385.603B trailing revenue on 2024-08-15, and does not exist on 2024-07-15. S&P 500 members of 2025-06-30, as knowable that day: revenue for the newest quarter 500 of 500 (498 with a 2025 quarter-end), trailing revenue 495, its growth 490; net income 499 / 490; operating cash flow 500 / 497; diluted EPS 494 / 483. Check 64.
- **Two JKP accounting factors, no price needed** (2026-10-12). `gross_profit_to_assets` is a `concept_ratio` row (gross profit over fiscal year-end total assets: Novy-Marx 2013, JKP `gp_at`), so it resolves in every as-of accessor and in `peer_stats_asof`, where an `ORDER BY value` is the factor sort: 297 S&P 500 constituents of 2024-11-15 carry one, Apple FY2024 0.4950, financials none (no gross profit line). Standardized unexpected earnings in the Foster, Olsen and Shevlin (1984) form, `sec_gold.as_of_surprise(cik, asof)` and `sec_gold.surprise_asof(index, asof)`: the year-over-year change in the newest quarter over the standard deviation of the eight prior changes, which must come from eight consecutive quarters or the answer is NULL; every input a vintage knowable on the date, from `as_of_quarterly`. S&P 500 on 2024-07-15: 472 of 501 ranked, Apple −0.20, about 10 s, **nothing stored**. Check 66.
- **Two more JKP factors, chosen by measured alpha** (2026-10-12). `ocf_to_assets` is a `concept_ratio` row (operating cash flow over fiscal year-end total assets; Bouchaud, Krueger, Landier and Thesmar 2019, JKP `ocf_at`): 497 S&P 500 constituents of 2024-11-15 carry one, Apple FY2024 0.3240, banks included since they file cash flows. Quarterly return on equity and on assets (JKP `niq_be`, `niq_at`), `sec_gold.as_of_profitability(cik, asof)` and `sec_gold.profitability_asof(index, asof)`: the quarter's net income over the balance at the end of the prior quarter, NULL when that balance is missing or not positive; S&P 500 on 2024-07-15, 454 of 501 with an ROE, 488 with an ROA, Apple 0.3190, about 40 s, **nothing stored**. Chosen because over JKP's published US factor returns, 2010-2025, `ocf_at` and `niq_be` are the strongest accounting factors the concepts can build exactly (CAPM alpha 5.6 and 5.4 points a year, t 2.8 and 2.7). `peer_stats` grew 8 MB for the ratio; every existing row byte-identical (row-level diff).
- **The factor sheet, and the quarterly function made deterministic** (2026-10-12). `sec_gold.factor_sheet_asof(index, asof)` is one row per constituent with nine factors (gross profit and operating cash flow to assets, ROA, ROE, operating margin, revenue growth, quarterly ROE and ROA, SUE), each as a value, an index percentile and a GICS-sector percentile signed so that higher means the higher expected return in the literature, and an equal-weight composite; S&P 500 on 2024-07-15: 501 rows, 496 with a composite, about 100 s, **nothing stored**. `as_of_quarterly` picks between candidates of equal standing by rule (newest vintage, shortest year-to-date pair, then tag and value) instead of by plan: 29 S&P 1500 members of 2024-07-15 had come out either way between runs. The sheet is one row per company: when the crosswalk still assigns a seat's ticker to its previous holder (the S&P 500's IR and TT both resolve to Trane Technologies for March to May 2020, the only such index-months since 2010) the company appears once rather than ranking twice; check 71 pins the count (2026-10-13).
- **Prices, the stored factor panel and the backtest** (2026-10-12). `sec_market` (a vendor, not SEC data): `uv run dera load-prices` fetches month-end closes from Yahoo Finance for the primary ticker of every company ever in the S&P 1500 whose ticker is still listed (303,761 company-months, 1,693 companies, 2009-01 to 2026-09), keeps Yahoo's split-restated and total-return closes and reconstructs the as-traded close from the split ratios (Apple July 2020: 425.04, not 106.26); `price_at` and `market_cap_at` take the newest month end strictly before the knowledge date, times the cover-page shares knowable on it. The equal-weight return of the priced companies correlates with the Fama-French market at 0.93 (2010-2026). **Survivorship**: 718 of 2,417 members ever have no open listing and no prices; every backtest here holds survivors only. `uv run dera build-factor-panel` stores `factor_sheet_asof` at every month end (quarter ends first) in `sec_market.factor_panel`, whose CHECKs refuse any row dated past its own knowledge date (they caught Catalent's mis-dated quarter, which led to the suspect-fact exclusion); `sec_market.backtest(index, factor, freq)` sorts the panel into equal buckets on each rebalance date, monthly, quarterly or annual, holds equal-weighted to the next, and `backtest_summary` reports per bucket and for the top-minus-bottom spread the mean monthly return, t-statistic, annualised return, Sharpe ratio and hit rate. Panels for the S&P 400 (from 2011) and 600 (from 2018) are built the same way, and `--index SP1500` writes their union with the S&P 500 re-ranked over all 1,500 names, one row per company, the same signing and composite rule as the sheet (`build_factor_panel_union`; check 72; 2026-10-13).
- **Every member has a GICS sector where any page ever gave one** (2026-10-13). The S&P 400 page from 2013-10 to 2019-08 and the S&P 600 page before 2021-03-31 carried a sub-industry and no sector, and the sector level is what the as-of cross-sections rank in, so the S&P 400 had no annual factor in 2017 and the S&P 600 none before 2021. The spine fills the sector by rule (the sub-industry's sector in the nearest-dated sighting of any index, then the company's own nearest sector) and maps every spelling to a canonical sector (`sec_reference.gics_sector_canonical`): 15,059 sector-less sightings become 547; "Healthcare" and "Health Care" are one peer group. Proof: every `index_membership` interval keeps its key (6,342 before and after; 1,741 label-only changes), membership and tickers at every month end since 2008 are identical, and `peer_stats` gains 55,496 sector-level rows, loses the 2,913 rows of the two misspelled groups, and changes no company's own value. The fill is a label on the same intervals, never a boundary: merging the segments a missing sector had split moved the CIK-succession cuts across seats a registrant absorbed (BancorpSouth/Cadence, Ashland, Fox; 192 member-months) and was withdrawn, and those cuts' own defects are listed as open in `docs/data_sources.md` section 4. Check 73.
- **Suspect facts stay out of gold** (2026-10-12). `sec_gold.suspect_fact` lists the silver rows the gold layer refuses, and `tradable_financials`, `fact_asof`, `get_canonical` and `latest_annual` anti-join it, so every function above them inherits the exclusion. Two reasons, each decided from the filing and earlier filings only so a flag never changes with later data: a period ending after its own filing date (5,546 facts of 1,047 filers; Catalent's 10-Q of 2024-02-14 dating a quarter to 2024-03-31, which the factor panel's own CHECK caught), and a balance-sheet column printed in thousands or millions without saying so (87 facts of 8 filers; Hill-Rom's FY2021 total assets of 4,999.1 dollars, which had put a return on assets of 49,709 atop every sort). The scale rule was measured until nothing real was caught: looser rules flagged post-impairment income lines at Cliffs and Valaris and SPAC redemptions, all real.
- **A zero total debt comes from the balance sheet, not from a missing tag** (2026-09-11). `sec_silver.pre_silver` keeps every statement line as the filer printed it, and `sec_gold.debt_face` reads each 10-K and 10-Q balance-sheet face for borrowing lines by their labels. A company whose total debt neither a tag nor a formula produced reads zero only when its newest annual face is complete, shows no borrowing line with a value, has no borrowing line without an undimensioned value, its interest expense is nil, and it is not a bank; every zero cites that filing, every refusal its reason. Measured against 135 members verified two ways: 90 zeros among the 109 debt-free, none among the 23 with debt; no existing value moved (snapshot diff at build: 0 changed, 0 lost; the only non-zero rows that appeared are members of thin sub-industry groups that a zero-debt peer lifted over the five-member minimum, scored for the first time with the values they already had). FY2024: 145 members at zero, `total_debt` for 1,347 tracked issuers, `debt_to_equity` 1,292. Check 63. No override list: the rule runs on every filing since 2009 and on each new quarter through the fold.
- **S&P 400 and 600 concept gaps: the instrument sum** (2026-09-11). A bank, insurer or REIT files no current/noncurrent split, only its balance-sheet lines (FHLB advances, subordinated debt, trust-preferred debentures; mortgages, unsecured notes, the revolver), so `total_debt` gains a second formula variant that sums them, for those three industries only and never past a custom-namespace debt line at the date (`concept_formula_variant`, 19 unscored instrument-line concepts, 37 tag rows). Measured first: the lines are disjoint (never the same value across 43 secured/unsecured filers), 51 of 212 banks and 39 of 129 REITs carry a custom line the sum would miss and are refused (Home Bancshares, Omega Healthcare, CNO), and non-financials fail an interest-expense sanity check in 98 of 259 cases and are excluded. FY2024 total debt: S&P 400 299 → 325 of 400, S&P 600 397 → 452 of 600, S&P 500 434 → 448 of 501, 1,133 → 1,229 tracked issuers; 693 company-years gained, none lost. Five revenue rows (gas utilities' `RegulatedOperatingRevenue`, advisory boutiques' `InvestmentBankingRevenue`, mortgage REITs' and Navient's gross interest income, `RevenuesExcludingInterestAndDividends`) take the S&P 600 to 584 of 600, with the generic totals restated above each industry line so a filed total keeps winning; 12 broker revenues move from a component to the filed total (Stifel, Virtu). Found on the way and fixed: no tag walk filtered on unit of measure, and Berkshire's FY2023 total debt was 1.26 trillion yen read as dollars. Check 62. Not done, by decision: 148 members file no debt line and no interest expense and are not asserted to be debt-free.
- **S&P 500 concept gaps closed where the filings allow.** 24 us-gaap debt tags (two more totals, six noncurrent and seven current lines: JPMorgan's 401B is `LongTermDebtAndCapitalLeaseObligationsIncludingCurrentMaturities`, Goldman's 243B `UnsecuredLongTermDebt`, Oracle's 85B `LongTermNotesAndLoans`) take FY2024 `total_debt` from 414 to 436 of the 502 members of 2024-12-31 and from 1,063 to 1,133 tracked issuers; the noncurrent operand is now required, so the 26 totals that were the current portion alone (Deere) are NULL instead of wrong. Revenue rows for non-bank lenders (SIC 61) and REIT lease income take FY2024 revenue to 500 of 502; APA files only custom tags. Still unresolved by design: 16 REITs (secured/unsecured pairs), asset managers, and issuers that tag debt by segment.
- **Gold joins a non-overlapping membership timeline.** `sec_reference.index_membership_timeline` resolves `index_membership` once per company (replayed history beats a snapshot, then the later start; an EXCLUDE constraint forbids overlap) and the three membership-reading matviews join it with a plain range condition instead of a per-fact LATERAL. Full gold build 32 → 25:42 min (2026-09-04); `fact_asof` is 19:36 of that; its bare query runs in 64 s (three hash joins over 97.9M rows), so the remainder is Postgres writing its 22 GB heap and 10 GB of indexes, and a redundant cik-only index (653 MB) is gone. `run_sql_dir` prints each file's seconds.
- **73-check verification suite** in `tools/verify_pit.sql`, run by `dera verify` (~15 min as of 2026-10-13, the as-of cross-section checks dominate); checks 29–73 each name the 2026-09-04 review defect, or the gap closed since, that they guard. Plus 166 unit tests (`uv run pytest`, no database) and GitHub Actions running `ruff` and `pytest` on every push.
- **Doc-staleness checker.** `dera verify-docs` validates every database object name — in prose and inside SQL examples — file path, CLI command and cross-link in the Markdown against the live repo and database.
- **`dera rebuild-reference` refreshes what changed.** It reloads the reference CSVs (the fetch tools never write the database, and this stage was missing), refills the spine in place so the gold matviews survive, rebuilds the security model and refreshes only the matviews whose inputs changed, decided by digesting the spine tables before and after: a crosswalk change refreshes four matviews and leaves the 33 GB `fact_asof` alone (about 6 minutes end to end), a mapping change refreshes one, and nothing changed means nothing refreshed (52 seconds). Every spine rebuild used to drop gold with CASCADE and cost a 32-minute rebuild. `build-silver` without the filing index preserves the security model instead of emptying it.

**Missing for serious research**:
- **Prices.** Still the biggest gap and nothing else is testable without it. The share-count denominator exists (`share_class_shares`, availability-correct, delisted issuers included) — prices are the only missing input.
- **Debt coverage, the remainder.** Of the 135 S&P 400/600 members of 2024-12-31 with no plain debt line (verified 2026-09-11 against every DERA fact and an external balance sheet), the 109 debt-free now read zero from their balance-sheet face where the face allows it (98 of them; the rest show a debt line at "—" or interest that contradicts an empty face and stay NULL, listed by `debt_face.reason`). The 23 with debt stay NULL by design: custom tags (Brixmor, Community Financial), dimensioned-only facts (Cinemark, Hudson Pacific, Kennedy-Wilson) and mortgage-REIT repurchase agreements (Annaly, Armour, Ellington). Reading those lines' values from the face would be the next step, and it is not taken: it changes figures that resolve today. 26 members are refused by the custom-line guard, and about 60 non-financials file instrument lines the variant does not apply to. Brokers and lenders (SIC 61–62) are excluded from the sum: a third carry custom lines.
- **36 constituent tickers remain unresolved** (`sec_reference.index_membership_unresolved`), none of them a company with facts in DERA: 25 pre-2010 S&P 500 names that never filed XBRL (Millipore, Sun Microsystems, Black & Decker, Centex, ...); on the S&P 400 a mangled row, a stray heading, a one-capture ambiguity and five ghost rows from the late-2020 captures; on the S&P 600 two typos and a bank that files with the FDIC. Closing the first group needs a pre-XBRL company spine. Membership dates are month-granular; the page's "changes" table has exact dates.
- **Pre-2019 ticker labels, the remainder.** The back-extension took the 2015 universe from 2,420 unlabelled members to 1,476 and made `cik_at('AAPL', DATE '2015-06-30')` resolve; 65 of the 518 S&P 500 members of mid-2015 still have no ticker for that date. What is left is a company that delisted before 2018-12 and never appeared in SEC's file, or a ticker that changed before then (Meta was FB, and the ticker-keyed `as_of_snapshot` raises for it; use the CIK overload). Dating ticker changes from 8-K Item 5.03 filings, or a vendor with delisted coverage, would close it.
- **`already_reporting` is early for some issuers, and only a stricter universe can avoid it.** 52.5% of securities date their first trade from the first periodic report; 1,738 of them carry a 424B pricing after it. `filers_10k_15m_strict` enters those at the pricing, which is right for OTC micro-caps and non-traded REITs and late for a pre-EDGAR listed company whose 424B was a follow-on (59 of the 216 that leave the 2015 universe). Filings cannot tell the two apart; a listing-history vendor could.
- **Dual-class issuers outside the S&P 500 are unmapped.** roughly 2,100 companies in the spine have reported two or more share-class members; 66 are mapped. The cover-page tool works for any CIK with an inline-XBRL 10-K (`--cik`), so extending it to the 400 and 600 is a run, not a design. Six S&P 500 covers say only "Common Stock" against A/B members (Blackstone, CDW, Domino's, Interactive Brokers, Zoetis, Quanta) and unlisted classes (Meta B, Nike A, Visa B/C) need a cited conversion ratio before their market caps are complete.
- **Delisting returns.** `delisting_event.delisting_return` is declared and
  NULL for all **7,119** outcomes. It needs prices, and it is the reason
  this is not yet a reliable backtester. The business cause of an outcome
  (acquisition, bankruptcy) is not derived either; `reason` records only the
  evidence class.
- **Multi-class mapping, remaining.** The cover-page scraper exists and is the way in; what remains is running it beyond the S&P 500 and citing conversion ratios for unlisted classes.
- Scale-free metrics that need a market value (FCF yield, earnings yield) or invested capital (ROIC). Margins, ROE/ROA, leverage and year-over-year growth shipped 2026-09-04 through `concept_ratio`.
- Factor library — the market side (value, momentum, size, low risk) requires prices. The accounting side started 2026-10-12 with gross profit to assets and SUE; the other JKP accounting factors the 47 concepts can express (`ocf_at`, `oaccruals_at`, `noa_at`, `at_gr1`, `saleq_su`) are the same two shapes, a `concept_ratio` row or a window over `as_of_quarterly`.
- Form 13F / Form 4, research SDK, parquet exports.
- Long-tail XBRL tag coverage for company-extension namespaces.
- **Footnote items outside `sec_data`.** The Notes data sets (27.6 GB, 80 archives) supply what the statement-only database lacks: defined-benefit pension assets and obligations, business-segment revenue and major customers, as Compustat-style files under `data/exports/compustat/` (`docs/compustat_items.md`, "Footnote items"). Not loaded into the database.

---

## Shipped

In reverse chronological order. The 2026-09-04 review landed as six commits; the S&P 500 membership, share-class and ticker back-extension work followed the same day.

- (this commit) — feat(tools): `tools/score_methods.py`, the same nine factors and composite scored three ways within each sector (AQR: z of rank; MSCI: 5/95-winsorised z; Barra: 3 sd-winsorised z, equal-weighted mean) and sorted strictly sector-neutral (within-sector quintiles, sector spreads weighted by member count), raw and against FF5 and FF5+UMD, as `docs/reports/score_methods_sector_neutral_2026-10-14.html`; single-factor sorts coincide by construction, the composites differ little; nothing written to the database
- `19f613e` — docs: the schema overview's sizes and row counts re-measured (2026-10-14, 164 GB; the 2026-09-04 figures predated three changes to the fact matviews' queries and two quarterly loads), the free space the folds leave in `sec_silver.num_silver` measured with `pgstattuple` (6.5 GB, 11.6% of the heap; the other large heaps 1–3%) and that extension noted as optional in the README
- `334da42` — docs(reports): the four backtest pages made current for their own universe (the sector fill, the 1,500-name backtest fix, the S&P 600 capture gap, the seat-by-registrant defects, measured from the panel rather than copied from the S&P 500 page; every table and chart byte-identical to the previous build) and the overview page `docs/reports/factor_backtest_overview_2026-10-13.html` (`tools/factor_report.py --overview`: the four universes side by side, every sort in every universe, the composite spread's path, what the S&P 1500 union is, what is fixed and what is open, the recommendation); the stale check and test counts in this file and `docs/schema_overview.md` corrected
- `90dc35a` — feat(reference,market): every member has a GICS sector where any page gave one (`sec_reference.gics_sector_canonical`, the date-aware fill in `sql/05_spine/020_index_membership.sql`, check 73; the S&P 400 had no annual factor in 2017 and the S&P 600 none before 2021); the S&P 400, 600 and combined 1500 panels built and backtested, four reports; the backtest resolves the as-of ticker once per member-date (the 1,500-name panel ran past thirteen minutes a call); `build-silver --quarter` refreshes `suspect_fact`; check 63 judges banks by the filing's SIC
- `85e35c2` — docs: the factor backtest report as one self-contained HTML file (`docs/reports/factor_backtest_SP500_2026-10-13.html`, generated by `tools/factor_report.py`)
- `e02a0a7` — fix(gold): the factor sheet one row per company (`sql/03_gold/090_factor_sheet.sql`); check 71 pins the duplicate-seat index-months (three, all Trane Technologies 2020); the S&P 500 factor panel built at every month end 2010-01 to 2026-09 and the backtests run against Fama-French five factors and momentum (`tools/ff_baseline.py`; nothing pays, status snapshot)
- `63b12cc` — fix(gold): suspect facts refused structurally (`sec_gold.suspect_fact`, `sql/03_gold/028_suspect_fact.sql`; anti-joins in 030, 035, 060, 070; the refresh plan); check 70; each matview `ANALYZE`d inside the one-transaction build and after every REFRESH, and `peer_stats`'s fiscal-year-end check rewritten from a per-row `EXISTS` to a join after the unanalysed form ran eleven hours
- `eb40b7d` — feat: the factor sheet (`factor_sheet_asof`, `sql/03_gold/090_factor_sheet.sql`); deterministic tie-breaks in `as_of_quarterly`; month-end prices from Yahoo (`sec_market.monthly_price`, `dera load-prices`, `dera_pipeline/prices.py`), `price_at`, `market_cap_at`, the stored factor panel (`dera build-factor-panel`) and `backtest` / `backtest_summary` (`sql/07_market/`); checks 68 and 69
- `bfdc98c` — feat(gold): four JKP accounting factors without prices: `gross_profit_to_assets` and `ocf_to_assets` as `concept_ratio` rows; standardized unexpected earnings (`as_of_surprise`, `surprise_asof`, `sql/03_gold/068_surprise.sql`) and quarterly return on equity and assets over the prior quarter's balance (`as_of_profitability`, `profitability_asof`, `sql/03_gold/069_profitability.sql`) on demand; checks 66 and 67
- `ac9fad2` — fix(gold): `shares_outstanding_at` sums share classes per period length (a 10-Q's quarter and six-month averages had been added: Berkshire 4.31B for 2.155B, Erie Indemnity in 2010; 58 of 13,266 evaluations moved, all of them down); the gross-profit flow guard deployed to `as_of_canonical` and `peer_stats`; check 15 pinned to a fixed date. 65/65
- `f9c1151` — docs: the 2026q3 load, the first new quarter folded in; nothing knowable by 2026-06-30 moved
- `89e963f` — fix(compustat): review of 2026-10-01. Supersession among 10-K/10-Q vintages only (an 8-K recast had emptied later vintages); quarterly values as known at rdq (25.7% of quarters had used later-reported numbers); Q4 share counts; one datadate per fyear; sign-normalised capx/dp/xint/xrd; components by FASB's calc tree (debt with finance leases, inventory), S&P's COGS identity and bank COGS, corrected NI/IB/EPSPX/DP fallbacks; presentation rules (`compustat_presentation_rules.csv`): structural zeros from the face statements, Revenues refused when it includes other income, redeemable preferred in SEQ/PSTK; pension location vs undimensioned order
- `b1eaa04`, `22b698f` — feat(notes): footnote facts from the SEC Financial Statement and Notes data sets (`tools/fetch_notes_datasets.py`, `tools/extract_notes_facts.py`) and Compustat-style pension, segment and customer files (`tools/export_notes_items.py`, `dera_pipeline/notes_items.py`): pension totals by an allowlist of plan-type members, OPEB excluded, audited by the funded-status identity
- `f9ff128` — feat(compustat): quarterly export (`tools/export_compustat_quarterly.py`): fiscal quarter, Q4 as year less nine months, year-to-date items, rdq from tradable_from
- `3240acf` — feat(compustat): S&P balancing-identity audit (`tools/audit_compustat_items.py`); "other" items as S&P remainders; liability and equity fallbacks; the export's fact cache keyed to its tag list; `load_map` refuses a row with an unquoted comma
- `3d3133f` — feat(compustat): point-in-time annual export (`tools/export_compustat.py`): one row per fiscal year and availability date, Compustat units; adds `polars` and `pyarrow`
- `b22753d` — feat(compustat): Compustat-style items from XBRL by a cited map (`dera_pipeline/compustat.py`, `data/reference/compustat_item_map.csv`, 85 items); validated against the FASB taxonomy, rules unit-tested
- `463bb00`, `f4494bc` — feat(tools): FASB definitions and calculation context for US-GAAP elements (`tools/fetch_usgaap_element_docs.py`), the evidence base for mapping Compustat items
- `289bd86` — fix(gold): the gross-profit figures regenerated by `tools/audit_gross_profit.py`; one cited share was computed over the wrong denominator (1.7%, is 66.0%)
- `2b48619` — feat(gold): gross profit in taxonomy order with guarded goods/services components: `cost_of_revenue` walks `CostOfRevenue` first, `cost_of_goods` / `cost_of_services` recover pre-2021 component filers, a custom-cost-line guard on the income statement; the quarterly resolver and `peer_stats` honour every variant and guard
- `858a341` — feat(tools): the FASB US-GAAP taxonomy's gross-profit element tree, 2011–2026, as evidence for the `cost_of_revenue` tag order (`tools/fetch_usgaap_cost_elements.py`)
- `dc5c451` — feat(gold): quarterly flows and trailing twelve months on demand: `as_of_quarterly`, `as_of_trailing`, `quarterly`, `trailing`; nothing stored
- `e007c17` — fix(reference): a membership interval never names a registrant before its first EDGAR filing: the seat's "date added" no longer back-dates a successor (Paramount Skydance), a successor's pre-handoff interval is cut at its first filing (Alphabet), and a successor not yet in DERA is a succession (Exxon Mobil)
- `acca99e` — feat(gold): a zero total_debt from a debt-free balance-sheet face; pre_silver keeps the statements' layout
- `b617e45` — fix(gold): the instrument-sum guard no longer exempts a custom debt line named after its premium or discount; the no-debt-line members verified against two sources
- `d3e4d25` — feat(gold): total_debt sums the instrument lines of a bank, insurer or REIT, guarded against custom lines; five industry revenue rows; every tag walk in dollars
- `aac6b44` — feat(reference): constituent runs resolve by a dated name, a cited allowlist and the neighbouring run across partial captures; 138 unresolved tickers become 36
- `8ff29b4` — docs: the October quarterly sequence rehearsed on 2026q2; the 1,701-company refresh explained as the pre-replay population
- `de8da3f` — fix(gold): map the continuing-operations operating-cash-flow tag; document the tag-name families
- `137712f` — feat(pipeline,reference): bronze source_quarter and the incremental silver fold; the S&P 400 and 600 replayed; CIK succession
- `5383236` — feat(gold): peer_stats_asof, the knowledge-date peer cross-section as an on-demand function
- `be750b6` — feat(gold): margins, returns, leverage and year-over-year growth as concepts, scored in peer_stats and resolved by every snapshot
- `b72d4e3` — feat(security): filers_10k_15m_strict, a universe that enters a reporting-before-listing issuer at its first priced offering
- `8e25dc7` — fix(gold): peer_stats balance concepts take the fiscal year-end balance, not the latest quarter inside the window
- `1b1fb40` — feat(gold): close the S&P 500 total_debt and revenue gaps with 24 us-gaap tags; require the noncurrent operand so a total is never the current portion alone
- `efcf4a0` — perf(gold): a non-overlapping membership timeline replaces the per-fact LATERAL in the three membership-reading matviews
- `722aaed` — perf(reference): refill the spine in place; rebuild-reference reloads the CSVs and refreshes only the matviews whose inputs changed
- `c14ea0e` — feat(spine): back-extend single-ticker histories before the archive floor; every as-of ticker flag is observed-only
- `5e7cbde` — feat(reference,gold): dated S&P 500 membership from Wikipedia revisions; share classes decided by the filings and mapped from 10-K cover pages
- `7947ee4` — docs: reconcile every document with the 2026-09-04 review — every number re-measured and date-stamped; the 48%-vs-57% contradiction resolved
- `1c4ca96` — test: 42-check verify suite, 82 unit tests, CI
- `65a70d2` — fix(pipeline): reload guard, computed default quarter, 404 handling, doc-checker blind spots, dead indexes
- `4a91330` — fix(gold): derived-concept fallback in both lookup families, strict tickers, delisted issuers in the share denominator, pre-2018 revenue
- `c856c88` — fix(security): anchored form classification, Form 15 outcomes, listed classes only, no lost listings
- `ce49406` — fix(crosswalk): monthly captures, no fabricated live snapshot, capture-quality gap bridging

- `705b2c0` — chore: add the pre-commit doc-staleness hook
- `4510fbe` — docs: make the doc-currency rule explicit and enforceable
- `b0526d3` — docs: eliminate documentation staleness and add a checker that prevents it
- `2e0f84d` — docs: bring README and architecture current; add schema overview
- `7f69d99` — feat(reference): scale the security model to 17,031 securities
- `39fe460` — feat(reference): security lifecycle model; separate company from security
- `11b5967` — feat(gold): per-share-class counts; fix two class-summing defects
- `34379aa` — feat(gold): derived-concept mechanism; fix total_debt understatement
- `4698a5a` — perf(gold): join ticker instead of per-row call; add GICS; two-level peer_stats
- `3eedd5f` — test: add PIT verification suite; rebuild silver and gold
- `a05ac89` — feat(silver,gold): bitemporal facts, as-of accessors, crosswalk fan-out fix
- `0aacf2f` — fix: seven correctness and safety defects from external code review
- `5de661f` — feat(pit): filing-availability foundation and survivorship-free crosswalk

- `113f66d` — feat(gold): add peer_zscore_by_sub_industry matview + broaden revenue tags <!-- check-docs:ignore renamed to peer_stats in 4698a5a -->
- `5bfd54f` — feat(gold): fiscal-year-aware latest_annual + snapshot, fix capex tag
- `b4e5299` — feat(gold): add canonical_concepts + get_canonical() function
- `4e9ae82` — feat(reference): capture GICS sector and sub-industry for S&P 1500
- `df546f8` — fix(cli,silver): skip redundant gold REFRESH; size work_mem for num_silver
- `7606a2d` — fix(loader): commit per quarter so load_all is incremental and visible
- `89a34ce` — fix(loader,gold): handle embedded tabs in segments; bypass function in matviews
- `ffb3c61` — docs: rewrite README for medallion pipeline, add architecture.md
- `61bae13` — chore: relocate tree, delete legacy scripts, update gitignore
- `e658f9f` — refactor(sql): reorganize into bronze/silver/gold/reference tree
- `98dc2a5` — feat(python): add dera CLI entry point
- `cd9f7d3` — chore: switch from pip/requirements.txt to uv-managed pyproject.toml
- `fd61e71` — feat(python): add psycopg3-based bronze loader
- `f44d4e4` — feat(python): add dera_pipeline package skeleton

### Resolved by the 2026-09-04 review, for the record

- **The dropped listing intervals are explained.** Of 26,277 candidate intervals on the old crosswalk, 2,988 lay outside the security's life; 2,938 were tickers first observed *after* the delisting (2,209 of those delistings predate the 2019 floor, only 4 of the companies filed anything a year later) and 50 were "ticker gone before first trade". SEC's file carries dead entries for years — the June 2020 purge removed 7,879 at once — so this was never a late `first_trade_date`.
- **The old "current" crosswalk snapshot was the December 2025 local file stamped with the run date** (an exact set match). It resurrected 1,334 retired tickers as current, Electronic Arts among them. The fallback is gone.
- **Partial archive captures manufactured 2,459 false ticker gaps**; the spine now flags them and bridges short silences.

---

## Tier 2 — In scope, not yet started

### Price + market cap pipeline

**Problem**: Fundamentals without prices is close to useless for quant research. You can't compute P/E, EV/EBITDA, momentum, size, returns, or point-in-time market cap without a daily price history.

**Shipped, the smallest version** (2026-10-12): month-end closes from Yahoo Finance for the primary ticker of every company ever in the S&P 1500 whose ticker is still listed, in `sec_market.monthly_price` (`uv run dera load-prices`), with the as-traded close reconstructed from split ratios, `price_at` and `market_cap_at` as of a knowledge date, the stored factor panel and the backtest (status snapshot above; `docs/data_sources.md` section 8). It is a stopgap keyed the way the full layer will be: no delisted company has a series (718 of 2,417 members ever), which is the survivorship gap only a source with delisted history closes.

**What the first backtest says** (2026-10-13; the full report with every bucket, alpha and loading is `docs/reports/factor_backtest_SP500_2026-10-13.html`; S&P 500, `sec_market.factor_panel` at every month end 2010-01 to 2026-09, 201 dates, 100,378 rows; equal-weight quintiles held to the next rebalance; `tools/ff_baseline.py`): nothing pays. Over the composite and the nine factors at monthly, quarterly and annual rebalancing, no top-minus-bottom spread has a raw t above 1.6 (the best raw is `gp_at` annual at 2.2% a year, t 0.89; `operating_margin` sorts the wrong way at −2.6% to −3.5%). Against Fama-French five factors the spreads are what they load on: RMW 0.3 to 0.56, HML −0.2 to −0.7, and the quarterly signals 0.25 to 0.30 on momentum; after FF5 only low `revenue_growth` at quarterly rebalancing reaches t 2.5 (4.3% a year), one of thirty tests, and it is the CMA-shaped sort (loading 0.4). The equal-weight benchmark earns 13 to 14% a year (t 3.2 to 3.4) with FF5 alpha −0.3% and R² 0.96: the returns and the French series line up. Two things bias the spreads down, not up: survivors only (66% of 2010 members have a price the next month, 98% by 2025), and a large-cap universe where the published profitability premium is smallest.

**The S&P 400, the S&P 600 and the three together** (2026-10-13; `docs/reports/factor_backtest_SP400_2026-10-13.html`, `..._SP600_...`, `..._SP1500_...`; the 400 from 2011, the 600 and the union from 2018-08, where their replayed histories begin): the same answer. S&P 400 (187 months): no raw spread above |t| 1.0; after FF5 none clears t 2, after FF5 plus momentum one (low revenue growth, monthly, 4.1% a year, t 2.08); the equal-weight benchmark earns 12.3% a year with FF5 alpha −1.1%, R² 0.96 and a size loading of 0.57. S&P 600 (96 months): the one raw spread past t 2 is gross profit to assets sorting the wrong way at annual rebalancing (−9.8%, t −2.03), and the two alphas past t 2 are operating margin sorting the wrong way (−7.9% a year, t −2.5 monthly and −2.3 quarterly) with a profitability loading of 0.75; the benchmark earns 9.5% a year (t 1.1), FF5 alpha −0.3%, R² 0.98, size loading 0.93. Only 65% of 2018 members have a price the following month in the 600 and 93% by 2025, so its bottom bucket is the most flattered of the three. S&P 1500, the three re-ranked together (96 months): nothing pays by any reading. No raw spread above |t| 1.0, no alpha past t 2 on either model (the strongest is the composite at annual rebalancing, FF5 alpha t −1.5, with a size loading of −0.4, so without a size control a sort across the 1,500 is partly a bet on large versus small); the benchmark earns 10.1% a year, FF5 alpha −1.3%, R² 0.98. Across the four universes and 120 tests, four sorts clear |t| 2 on a factor model (low revenue growth in the 500 at quarterly and in the 400 at monthly rebalancing; operating margin in the 600, monthly and quarterly, the wrong way), none in more than one universe, against six expected from noise at the 5% level, and no sort has the same sign with |t| above 1 in all four; the published premia do not show up in these point-in-time fundamentals at these sizes with these prices, and the survivorship gap is the first thing to close before concluding more. The four universes side by side, with the database changes and the recommendation: `docs/reports/factor_backtest_overview_2026-10-13.html` (`tools/factor_report.py --overview`).

**Three scoring methods, strictly sector-neutral** (2026-10-14; `docs/reports/score_methods_sector_neutral_2026-10-14.html`, `tools/score_methods.py`; nothing written to the database): the same nine factors and composite scored within each (date, GICS sector) group the AQR way (z-score of the rank), the MSCI way (raw value winsorised at the 5th/95th percentile, z-scored) and the Barra way (winsorised at mean ± 3 sd, z-scored; equal-weighted mean, one pass), then sorted the way AQR does it: within every sector, long the top fifth and short the bottom fifth, sector spreads averaged with member-count weights so the two sides carry identical sector counts (sectors under ten scored members left out). The choice does not change the answer. For a single factor the three scores order a sector identically, so the 108 single-factor sorts coincide by construction; the composites differ little (spread-series correlations between methods 0.95 to 0.99). Per method, 6 or 7 of 120 sorts clear |t| 2 on FF5+UMD against 6 expected from noise, 29 spreads are positive, the mean alpha t is −0.38, and the alpha's sign agrees under all three in 119 of 120. The sorts past 2 are earnings surprise monthly in the S&P 500 (t −2.40) and S&P 1500 (−2.04), operating margin monthly and quarterly in the S&P 500 (−2.18, −2.32), the S&P 600 composite monthly under all three (−2.2 to −2.4), and one positive: low revenue growth, monthly, in the S&P 400 (+2.61 under each method). Measured on the way: the bottom composite quintile has a next-month price for 65% (S&P 400) to 82% (S&P 500) of name-dates against 80% to 90% for the top, the survivorship gap in numbers.

**Recommended source** (re-researched 2026-10-14; Ryan's call, not yet subscribed): **Sharadar** (sharadar.com direct, personal-use licence): daily prices for about 21,000 active and delisted US stock tickers since December 1997, a total-return close and an unadjusted close, a `permaticker` that identifies an issuer across every ticker change, and an ACTIONS table with delisting dates, delisting reasons and acquisition counterparties; $299 a year for the full history, $499 with point-in-time fundamentals. Those two tables are what a survivorship-free backtest needs and what the crosswalk cannot supply itself. Monthly closes for the 2,417 members ever would roughly double `sec_market.monthly_price`; daily would add about 1.8 GB.

**Alternative**: **Polygon.io, renamed Massive in 2026**: delisted tickers through `active=false` with a delisting date, CIK and FIGI per ticker, daily aggregates and one flat file a day since September 2003; but keyed by ticker and date, so reused tickers must be stitched by CIK, and the tier that reaches 2009 is Advanced at $199 a month (Starter at $29 is five years, Developer at $79 ten). The better choice if intraday, real-time or options ever matter. The earlier note here recommending the $29 flat files was wrong about the history they include.

> **WARNING — do not build the matview below as written.** It has three
> defects, all fixed by work that landed after this section was drafted:
>
> 1. `rank_latest = 1` is the *restated* share count, pulled from a future
>    filing. This is precisely the look-ahead the bitemporal work removed.
>    Use `sec_gold.fact_asof` with the `tradable_from` / `superseded_tradable`
>    interval, or simply call `sec_gold.shares_outstanding_at(cik, asof)`.
> 2. It hardcodes `EntityCommonStockSharesOutstanding`, which covers 69%.
>    `shares_outstanding_at` already ladders five tags to 99.5% (1,490 of
>    1,498). The 69% figure actually measured `CommonStockSharesOutstanding`,
>    a different tag.
> 3. It joins `ticker_map`, which is survivorship-biased. Use
>    `sec_reference.cik_at(ticker, asof)`.
>
> The fourth defect, **multi-class issuers**, is now addressed on the share
> side. `sec_gold.share_class_shares` holds per-class counts and
> `share_classes_at(cik, asof)` returns one row per class with the ticker whose
> price applies. So the price loader should be keyed on **(ticker, trade_date)
> where ticker is a listed share class**, and market cap is
> `SUM(shares * price(price_ticker))` across the classes a company returns.
>
> Note an unlisted class such as Alphabet Class B carries
> `prices_with_ticker` rather than a ticker of its own, so it needs a price
> lookup against its reference class rather than being skipped.

**Proposed schema** (superseded — see warning above):
```sql
CREATE TABLE sec_gold.prices (   -- check-docs:ignore proposed, does not exist yet
    ticker       TEXT NOT NULL,
    trade_date   DATE NOT NULL,
    open         NUMERIC(12,4),
    high         NUMERIC(12,4),
    low          NUMERIC(12,4),
    close        NUMERIC(12,4),
    adj_close    NUMERIC(12,4),   -- split/dividend adjusted
    volume       BIGINT,
    PRIMARY KEY (ticker, trade_date)
);
CREATE INDEX idx_prices_date ON sec_gold.prices (trade_date);   -- check-docs:ignore proposed, does not exist yet

CREATE MATERIALIZED VIEW sec_gold.market_cap_daily AS   -- check-docs:ignore proposed, does not exist yet
SELECT p.ticker, p.trade_date, p.close,
       s.shares_outstanding,
       p.close * s.shares_outstanding AS market_cap
FROM sec_gold.prices p   -- check-docs:ignore proposed, does not exist yet
JOIN LATERAL (
    -- Point-in-time shares outstanding: most recent value as of trade_date
    SELECT dei_so.value AS shares_outstanding
    FROM sec_silver.num_silver dei_so
    WHERE dei_so.cik = (SELECT cik FROM sec_silver.ticker_map WHERE ticker = p.ticker)
      AND dei_so.tag = 'EntityCommonStockSharesOutstanding'
      AND dei_so.value_date <= p.trade_date
      AND dei_so.rank_latest = 1
    ORDER BY dei_so.value_date DESC LIMIT 1
) s ON TRUE;
```

**Acceptance criteria**:
- Daily OHLCV for every S&P 1500 ticker from 2009-01-02 → current trading day
- Adjusted close populated for every row
- `sec_gold.market_cap_daily` has one row per (ticker, trade_date) with PIT market cap <!-- check-docs:ignore proposed, does not exist yet -->
- Spot checks: AAPL 2020-03-23 (COVID bottom) close, NVDA 2024-06-18 post-split, BRK.A vs BRK-B handled

**Loader**: `dera_pipeline/prices.py` with `download_polygon_flat_file(date)` + `load_price_file(conn, path)` using `cur.copy("COPY sec_gold.prices ...")`. CLI: `dera fetch-prices --from 2009-01-01 --to $(date +%Y-%m-%d)`. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 1-2 days after Polygon.io signup.

---

### Incremental silver rebuild

**Status 2026-09-04**: shipped as `dera build-silver --quarter Q` (`sec_silver.build_quarter`), on a bronze `source_quarter` column; partitions the quarter touches are recomputed whole rather than merged, which is what makes the vintage columns come out exactly as a full build's. The proposal below is kept as written.

**Problem**: `dera build-silver` currently runs `CREATE TABLE num_silver AS ...` which is a full rebuild of all 185M rows (~39 minutes). Adding a single new quarter (2026q1 when it drops in mid-April) shouldn't cost 32 minutes.

**Approach**:
1. Add new quarter to `sec_raw.num_raw` via `dera load --quarter` (works today).
2. Compute silver rows for just the new quarter into a staging table.
3. `MERGE INTO sec_silver.num_silver USING staging ON (adsh, tag, ...) WHEN MATCHED ... WHEN NOT MATCHED INSERT`.
4. Recompute `rank_pit` / `rank_latest` only for partitions where the staging table introduced rows — a small subset of the full universe.

**Acceptance criteria**:
- `dera load --quarter 2026q3 && dera build-silver --incremental` completes in under 5 minutes. <!-- check-docs:ignore proposed flag -->
- Row counts in silver after incremental build match what a full rebuild would produce (check on a sample of 100 partitions).
- `rank_pit` values for historical quarters are unchanged (no look-ahead contamination from the new data).

**Risk**: The window function `ROW_NUMBER() OVER (PARTITION BY ...)` needs to be recomputed for any partition that got a new row. If the partition is (cik, tag, value_date, qtrs, uom, coreg, segments), a new filing for CIK X with tag Y and value_date Z only affects partitions with exactly those values — small fan-out.

**Effort**: 4-6 hours. Requires careful testing.

---

### Derived QoQ / YoY / TTM metrics

**Status 2026-09-04**: year-over-year growth of revenue, net income, EPS and operating cash flow ships in `peer_stats` and the snapshot functions via `concept_ratio` (fiscal-year aligned, positive base, consecutive years only). What remains of this proposal is quarter-over-quarter and trailing-twelve-month, which need quarterly (`qtrs = 1`) resolution that the canonical layer does not do yet.

**Problem**: Growth rates are central to both quant factors and fundamental analysis, and computing them at query time over 185M rows is slow. Pre-compute once per silver rebuild.

**Proposed matview**:
```sql
CREATE MATERIALIZED VIEW sec_gold.fundamentals_growth AS   -- check-docs:ignore proposed, does not exist yet
WITH base AS (
    SELECT ticker, cik, concept, fiscal_year, value_date, value
    FROM sec_gold.peer_stats  -- renamed; filter peer_level
)
SELECT
    b.*,
    LAG(value, 1) OVER (PARTITION BY cik, concept ORDER BY value_date) AS value_prev_period,
    LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date) AS value_prior_year,
    (value - LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date))
        / NULLIF(LAG(value, 4) OVER (PARTITION BY cik, concept ORDER BY value_date), 0)
        AS yoy_growth,
    AVG(value) OVER (PARTITION BY cik, concept ORDER BY value_date ROWS BETWEEN 3 PRECEDING AND CURRENT ROW) AS ttm_avg
FROM base b
WHERE concept IN ('revenue','gross_profit','operating_income','net_income','operating_cash_flow');
```

**Acceptance**: Query `WHERE ticker = 'NVDA' AND concept = 'revenue'` returns 15+ years of YoY growth rates with correct values (e.g., NVDA FY2025 revenue $130.5B vs FY2024 $60.9B → yoy_growth = 114%).

**Requires**: canonical_concepts layer (Tier 1, done).

**Effort**: 2-3 hours.

---

### Factor library (monthly cadence)

**Problem**: Systematic quant strategies want a single `sec_gold.factors_monthly` table with pre-computed factor ranks at each month-end for every S&P 1500 ticker. <!-- check-docs:ignore proposed, does not exist yet -->

**Proposed table**:
```sql
CREATE MATERIALIZED VIEW sec_gold.factors_monthly AS   -- check-docs:ignore proposed, does not exist yet
SELECT
    ticker, month_end,
    -- Size
    log(market_cap) AS log_mcap,
    -- Value
    market_cap / NULLIF(trailing_revenue, 0) AS ps_ratio,
    market_cap / NULLIF(trailing_net_income, 0) AS pe_ratio,
    (market_cap + total_debt - cash) / NULLIF(trailing_ebitda, 0) AS ev_ebitda,
    -- Quality
    trailing_net_income / NULLIF(total_equity, 0) AS roe,
    trailing_net_income / NULLIF(total_assets, 0) AS roa,
    total_debt / NULLIF(total_equity, 0) AS debt_equity,
    -- Growth
    yoy_revenue_growth, yoy_earnings_growth,
    -- Momentum
    (close / close_12m_ago - 1) AS return_12m,
    (close / close_1m_ago  - 1) AS return_1m,
    -- Composite
    percent_rank() OVER (PARTITION BY month_end ORDER BY ...) AS value_rank,
    ...
FROM ...;
```

**Requires**: prices (Tier 2), canonical concepts (Tier 1, done), peer z-scores (Tier 1, done), derived growth metrics (Tier 2).

**Shipped so far, without prices and without a table** (2026-10-12): `gross_profit_to_assets` and `ocf_to_assets` as `concept_ratio` rows (JKP `gp_at`, `ocf_at`), standardized unexpected earnings on demand (`as_of_surprise`, `surprise_asof`; JKP `niq_su` without its drift term) and quarterly return on equity and on assets on demand (`as_of_profitability`, `profitability_asof`; JKP `niq_be`, `niq_at`). Measured against JKP's published US factor returns (capped value-weighted terciles of all US stocks, CAPM alpha 2010-2025, points a year): `ocf_at` 5.6 (t 2.8), `niq_be` 5.4 (2.7), `gp_at` 3.8 (2.0), `niq_su` 1.8 (1.8). The rest JKP builds from items the concepts already cover are the same two shapes: `capx_gr1` 3.2 (2.4), `at_gr1`, `be_gr1a`, `niq_be_chg1` as registry rows or functions; `noa_at` 4.7 (2.8), `noa_gr1a` 4.4 (3.4, the strongest post-2010 accounting factor), `ebit_bev` and `sale_bev` approximately, with net operating assets as equity + debt − cash. Sloan's `oaccruals_at` is dead since 2000 (t 0.1). `cop_at` (the best full-sample factor), `ope_be`, the current-asset family, the F-, O- and Z-scores need SG&A, tax, inventory, receivables or current-asset tags that are not mapped, and each new tag grows `fact_asof`.

**Acceptance**: Run a naive "top-decile value" backtest in SQL against this table — should match published factor returns within ~50 bps/year over 2010-2024.

**Effort**: 1-2 days after prices land.

---

### ~~Sub-day accepted_time in num_silver~~ — DONE

**This item was already delivered under a different column name.** There is no
`sub_silver.accepted_time`; the acceptance instant is `known_at TIMESTAMPTZ`, and
`num_silver` carries it too (values span 2009-04-15 16:44 EDT → 2026-06-30 17:30
EDT). Intraday questions are answerable today. Retained only so nobody re-plans it.

**Original problem statement**: `num_silver.filed_date` is a `DATE`, losing the intraday precision captured in the submission record. For intraday backtests ("did I know X at 10:05 AM when the 10-Q dropped at 10:03 AM?") we need sub-day resolution.

**Approach**:
1. Add `accepted_time TIMESTAMPTZ` column to `sec_silver.num_silver`.
2. Populate it during silver build via `JOIN sub_silver USING (adsh)` — we already do that join.
3. Update `rank_pit` / `rank_latest` ORDER BY to use `accepted_time` before `filed_date` as the tiebreaker.

**Acceptance**: Query for a known intraday filing (e.g., AAPL Q2 earnings released after close) returns rows with non-midnight timestamps.

**Effort**: 30 minutes of SQL + one full silver rebuild (~39 min).

---

### Revenue from components (for banks without single-tag revenue)

**Problem**: Some large banks (USB, TFC in S&P 500) don't file a single `Revenues`, `RevenuesNetOfInterestExpense`, or similar headline revenue tag. They file only decomposed components: `InterestIncomeExpenseNet` + `NoninterestIncome`. **RESOLVED**: both now resolve in `sec_gold.peer_stats` — USB revenue FY2023–FY2025 is $30.0B / $31.7B / $31.0B and TFC $24.5B / $25.1B / $24.5B. Retained for the general pattern only.

**Fix**: Add a "derived revenue" computed as `InterestIncomeExpenseNet + NoninterestIncome` when no headline tag is available. Priority 5 in concept_tag_map, or a separate fact_type='derived_bank_revenue' concept.

**Affected tickers**: USB, TFC, a handful of smaller regional banks.

**Effort**: 1-2 hours. Needs either a derived-concept mechanism in get_canonical or a pre-computed view.

---

## Tier 3 — Later

### Form 13F (institutional holdings)

**Source**: SEC publishes 13F filings quarterly in a separate DERA dataset at `https://www.sec.gov/files/dera/data/form-13f/` (different from the Financial Statement Data Sets we already load). Contains every 13F filer's holdings above $100M AUM.

**Tables**: `sec_13f.filings`, `sec_13f.holdings(filer_cik, issuer_cusip, shares, value, quarter)`.

**Use cases**: ownership crowdedness, hedge fund tilt analysis, "who bought what this quarter" event signals.

**Effort**: 1 day — new bronze pipeline, parse SEC XML format.

---

### Form 4 (insider trades)

**Source**: SEC EDGAR full-text search API or bulk XML feeds. Not in DERA — requires scraping or using an EDGAR SDK.

**Tables**: `sec_insiders.transactions(cik, reporter_cik, transaction_date, code, shares, price_per_share, direct_indirect)`.

**Use cases**: insider buying/selling signals, cluster buying detection.

**Effort**: 1-2 days. Form 4 XML parsing is non-trivial.

---

### Python research SDK (`dera_pipeline.research`)

**Problem**: SQL is verbose for notebook-style research. A small Python layer would make the common patterns (screen, compare, backtest) one-liners.

**Proposed API**:
```python
from dera_pipeline.research import Screen, Company, Peer

# Screen for value + quality
candidates = Screen(universe='SP500', as_of='2024-12-31')
    .where(concept='pe_ratio', zscore_lt=-0.5)      # cheap vs peers
    .where(concept='roe', zscore_gt=0.5)             # quality vs peers
    .top(20)

# Deep dive
aapl = Company('AAPL')
print(aapl.snapshot())              # canonical concepts
print(aapl.peer_rank('revenue'))    # vs semiconductors sub-industry
print(aapl.history('revenue', years=10))
```

**Effort**: 1 day for a minimal v1 with 3 classes.

---

### Parquet export layer

**Problem**: Some research workflows are pandas/polars-native and want data in parquet files, not Postgres connections.

**Approach**: `dera export --matview peer_stats --output s3://bucket/path` — dumps a gold matview to a partitioned parquet file using psycopg + pyarrow. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 2-3 hours.

---

### Data quality monitors

**Problem**: A silent bad value can pollute research for months. We need proactive detection.

**Approach**: `sec_gold.magnitude_anomalies` matview that flags any value >100× the peer median for the same (concept, fiscal_year, sub_industry). Plus temporal self-consistency (value >10× a company's own trailing 4-year median). <!-- check-docs:ignore proposed, does not exist yet -->

**Acceptance**: Daily run surfaces <50 new anomalies per quarter; most are real data errors, not real outliers.

**Effort**: 4-6 hours.

---

### Earnings calendar (filing dates + surprise)

**Problem**: Event-driven strategies need to know when earnings were *released*, not just when the 10-Q was received by SEC. And they want the analyst consensus + reported surprise.

**Source**:
- Filing dates: already in `sub_silver.known_at` (the acceptance instant) and `tradable_from`.
- Press release timestamps: company IR pages or scraping 8-K filings for the `99.1` earnings exhibit.
- Analyst estimates: IBES/Zacks (licensed) or free aggregators like Zacks public API.

**Effort**: 3-4 hours for filing dates; additional 1-2 days for full surprise metrics.

---

### Backtest harness

**Problem**: We have data but not a way to test a strategy end-to-end.

**Proposed**: minimal `dera_pipeline.backtest` module:
```python
def run(universe, signal_fn, weight='equal', rebalance='monthly',
        start='2010-01-01', end=None, costs_bps=5):
    ...
    return BacktestResult(returns, turnover, metrics)
```

Uses the factor library for signals, the price layer for returns. Not a replacement for Zipline/Backtrader — just enough to sanity-check a factor.

**Effort**: 2-3 days.

---

### GICS Phase B (Industry Group + Industry levels)

**Problem**: We have Sector (11) and Sub-Industry (156 present in this universe; 163 in the full GICS taxonomy) today. Industry Group (25) and Industry (74) are missing.

**Approach**: Hardcode a 163-row `sec_gold.gics_hierarchy(sub_industry_name, industry_name, industry_group_name, sector_name)` table from S&P's public GICS taxonomy structure. Derivative from public structure, no licensing risk. View `sec_gold.sp1500_gics_full` left-joins universe_sp1500 to the hierarchy. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: 1-2 hours.

---

### Russell 3000 universe expansion

**Problem**: S&P 1500 covers ~1,500 names. Russell 3000 is ~3,000. Adds small-caps we currently can't screen.

**Approach**: Source from Russell's reconstitution announcements (public, scraped) or FTSE's API. Most of the code that reads universe_sp1500 today takes `WHERE` clauses, so adding a parallel `universe_russell3000` table is mostly additive.

**Catch**: Russell doesn't publish GICS for their constituents — we'd need to either accept missing GICS for non-S&P names or find a secondary source.

**Effort**: 3-4 hours.

---

### 10-K / earnings call transcript text analytics

**Problem**: A huge amount of alpha is in the management commentary section of 10-Ks and earnings call transcripts — sentiment, complexity, changes in tone quarter-over-quarter.

**Source**:
- 10-K text: SEC EDGAR raw filings (free but messy HTML).
- Transcripts: Seeking Alpha (scrape, gray area) or paid providers (AlphaSense, Sentieo).

**Approach**: Extract MD&A section via regex, embed with sentence-transformers, persist as `sec_gold.mda_embeddings`. Compute quarter-over-quarter cosine similarity as a "management tone change" signal. <!-- check-docs:ignore proposed, does not exist yet -->

**Effort**: Multi-day research project.

---

## Rejected / out of scope

- **yfinance for prices** — doesn't scale, unreliable (for a daily history of every US ticker). It is what loads the month-end closes of 1,868 index-member tickers in about ten minutes (2026-10-12), with the delisted-coverage gap documented; a daily, survivorship-free history still needs the paid source above.
- **IBES/Zacks analyst estimates** — expensive licensing, not worth it for a personal research setup.
- **Alternative data (credit card, satellite, web scrape)** — expensive, specialized, low ROI vs. fundamental research.
- **Options data** — different asset class, out of scope.
- **Bond-level data** — different asset class, out of scope.
- **Amending the refactor branch commits** — always create new commits, never force-push.

---

## How to use this document

**When starting a new session**, read:
1. "Status snapshot" — what's working today.
2. "Shipped" — recent commits in case something changed.
3. Pick an item from Tier 2 or Tier 3 and read its full spec.

**When shipping a new feature**:
1. Move the item from "Tier 2/3" to "Shipped" with the commit hash.
2. Update "Status snapshot" if the feature unlocks new capabilities.
3. Update every other doc the change touches — see the table in `CLAUDE.md`.
   `README.md`, `docs/architecture.md`, `docs/schema_overview.md`,
   `docs/gold_tables.md` and `docs/data_sources.md` are all expected to be
   current at every commit, not periodically caught up.
4. Run `uv run dera verify-docs` and `uv run dera verify`.
5. Commit the docs alongside the feature, never afterwards.

**When blocked**:
1. Add a note under the blocked item explaining the blocker.
2. Propose an alternative approach or escalate to the user.
