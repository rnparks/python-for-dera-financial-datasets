"""Unit tests for the pure functions in the pipeline.

No database, no network. Everything that talks to Postgres is covered by
`dera verify` (tools/verify_pit.sql) against the real data instead; the
point of this file is the logic that a database check cannot see going
wrong until it has already corrupted a build -- form classification,
quarter arithmetic, the .env parser, the header assertion, the crosswalk
file handling.

Run:  uv run pytest
"""

from __future__ import annotations

import csv
import datetime as dt
import os
import sys
from pathlib import Path

import pytest

from dera_pipeline import config, downloader, filings, loader, reference

sys.path.insert(0, str(config.PROJECT_ROOT / "tools"))
import check_docs
import fetch_ticker_history as fth
import fetch_usgaap_cost_elements as fuce
import fetch_usgaap_element_docs as fued

# ---------------------------------------------------------------------
# filings.classify: anchored, not prefix-matched
# ---------------------------------------------------------------------

@pytest.mark.parametrize("form,expected", [
    ("25", "DELISTING_NOTICE"),
    ("25-NSE", "DELISTING_NOTICE"),
    ("25-NSE/A", "DELISTING_NOTICE"),
    ("25/A", "DELISTING_NOTICE"),
    # Regulation A offering circulars are a capital raise, not a
    # delisting. The prefix bug classified 771 of these as Form 25 and
    # delisted 54 securities on the day they raised money.
    ("253G1", None),
    ("253G2", None),
    ("253G3", None),
    ("253G4", None),
    ("15-12B", "DEREGISTRATION"),
    ("15-12G/A", "DEREGISTRATION"),
    ("15-15D", "DEREGISTRATION"),
    ("15F-12B", "DEREGISTRATION"),
    ("15", None),
    ("8-A12B", "LISTING_REGISTRATION"),
    ("8-A12G/A", "LISTING_REGISTRATION"),
    ("8-A", None),
    ("S-1", "IPO_REGISTRATION"),
    ("S-1/A", "IPO_REGISTRATION"),
    ("S-1MEF", "IPO_REGISTRATION"),
    ("S-11", None),          # REIT registration, was swallowed by "S-1"
    ("F-1", "IPO_REGISTRATION"),
    ("F-10", None),          # Canadian shelf, was swallowed by "F-1"
    ("424B4", "IPO_PRICING"),
    ("424B1", "IPO_PRICING"),
    ("424B3", None),
    ("10-K", "PERIODIC_REPORT"),
    ("10-K/A", "PERIODIC_REPORT"),
    ("10-KT", "PERIODIC_REPORT"),
    ("10-K405", "PERIODIC_REPORT"),
    ("10-KSB", "PERIODIC_REPORT"),
    ("10-Q", "PERIODIC_REPORT"),
    ("10-QT/A", "PERIODIC_REPORT"),
    ("20-F", "PERIODIC_REPORT"),
    ("20-F/A", "PERIODIC_REPORT"),
    ("20FR12B", None),
    ("40-F", "PERIODIC_REPORT"),
    ("8-K", None),
    ("", None),
    ("10-k", "PERIODIC_REPORT"),   # case-insensitive
    (" 10-K ", "PERIODIC_REPORT"),  # whitespace-tolerant
])
def test_classify(form, expected):
    assert filings.classify(form) == expected


def test_every_rule_has_an_event():
    events = {e for _, e in filings.EVENT_RULES}
    assert events == {
        "LISTING_REGISTRATION", "DELISTING_NOTICE", "DEREGISTRATION",
        "IPO_REGISTRATION", "IPO_PRICING", "PERIODIC_REPORT",
    }


# ---------------------------------------------------------------------
# downloader: quarter arithmetic
# ---------------------------------------------------------------------

def test_iter_quarters_inclusive_and_wrapping():
    assert list(downloader.iter_quarters((2024, 3), (2025, 2))) == [
        (2024, 3), (2024, 4), (2025, 1), (2025, 2)]
    assert list(downloader.iter_quarters((2025, 1), (2025, 1))) == [(2025, 1)]
    assert list(downloader.iter_quarters((2025, 2), (2025, 1))) == []


@pytest.mark.parametrize("text,expected", [
    ("2025q3", (2025, 3)),
    ("2009Q1", (2009, 1)),
    ("  2026q2 ", (2026, 2)),
])
def test_parse_quarter_arg(text, expected):
    assert downloader.parse_quarter_arg(text) == expected


@pytest.mark.parametrize("text", ["2025", "2025q5", "2025q0", "q3", "2025-3"])
def test_parse_quarter_arg_rejects(text):
    with pytest.raises(ValueError):
        downloader.parse_quarter_arg(text)


def test_quarter_url_and_dir():
    assert downloader.quarter_url(2025, 3).endswith("/2025q3.zip")
    assert downloader.quarter_dir(2025, 3).name == "2025q3"


# ---------------------------------------------------------------------
# config: the .env parser and the default quarter
# ---------------------------------------------------------------------

def test_load_dotenv_sets_and_does_not_override(tmp_path, monkeypatch):
    env = tmp_path / ".env"
    env.write_text(
        "# comment\n"
        "DERA_TEST_A=\"quoted value\"\n"
        "DERA_TEST_B='single'\n"
        "DERA_TEST_C=plain\n"
        "not a pair\n"
        "\n"
    )
    monkeypatch.delenv("DERA_TEST_A", raising=False)
    monkeypatch.delenv("DERA_TEST_B", raising=False)
    monkeypatch.setenv("DERA_TEST_C", "from-environment")
    config._load_dotenv(env)
    assert os.environ["DERA_TEST_A"] == "quoted value"
    assert os.environ["DERA_TEST_B"] == "single"
    assert os.environ["DERA_TEST_C"] == "from-environment"  # env wins


def test_load_dotenv_missing_file_is_fine(tmp_path):
    config._load_dotenv(tmp_path / "absent.env")


@pytest.mark.parametrize("today,expected", [
    (dt.date(2026, 9, 4), (2026, 2)),
    (dt.date(2026, 7, 1), (2026, 2)),
    (dt.date(2026, 6, 30), (2026, 1)),
    (dt.date(2026, 2, 1), (2025, 4)),   # first quarter wraps to the prior year
    (dt.date(2026, 10, 1), (2026, 3)),
])
def test_last_completed_quarter(today, expected):
    assert config.last_completed_quarter(today) == expected


def test_secrets_fail_loud(monkeypatch):
    monkeypatch.delenv("SEC_USER_AGENT", raising=False)
    monkeypatch.delenv("PG_DSN", raising=False)
    with pytest.raises(RuntimeError):
        config.sec_user_agent()
    with pytest.raises(RuntimeError):
        config.pg_dsn()


# ---------------------------------------------------------------------
# loader: header assertion and quarter-directory detection
# ---------------------------------------------------------------------

@pytest.mark.parametrize("name,ok", [
    ("2025q3", True), ("2009Q1", True), ("2025q5", False), ("2025", False),
    ("2025q33", False), ("abcdq1", False), ("2025-3", False),
])
def test_looks_like_quarter(name, ok):
    assert loader._looks_like_quarter(name) is ok


def test_verify_header_accepts_exact_and_rejects_drift(tmp_path):
    good = tmp_path / "num.txt"
    good.write_text("\t".join(loader.EXPECTED_COLUMNS["num.txt"]) + "\nrow\n",
                    encoding="latin-1")
    loader._verify_header(good, loader.EXPECTED_COLUMNS["num.txt"])

    drifted = tmp_path / "num2.txt"
    cols = list(loader.EXPECTED_COLUMNS["num.txt"])
    cols[3], cols[7] = cols[7], cols[3]   # the historical coreg/ddate swap
    drifted.write_text("\t".join(cols) + "\n", encoding="latin-1")
    with pytest.raises(ValueError):
        loader._verify_header(drifted, loader.EXPECTED_COLUMNS["num.txt"])


def test_expected_columns_match_sec_layout():
    assert len(loader.EXPECTED_COLUMNS["sub.txt"]) == 36
    assert len(loader.EXPECTED_COLUMNS["num.txt"]) == 10
    assert loader.EXPECTED_COLUMNS["num.txt"].index("coreg") == 7
    assert set(loader.TARGET_TABLES) == set(loader.EXPECTED_COLUMNS)


# ---------------------------------------------------------------------
# reference: the calendar horizon guard fires before touching Postgres
# ---------------------------------------------------------------------

def _write_calendar(path: Path, last: dt.date) -> None:
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["session_seq", "session_date", "close_time_et", "close_at"])
        w.writerow([1, "2009-01-02", "16:00:00", "2009-01-02T16:00:00-05:00"])
        w.writerow([2, last.isoformat(), "16:00:00", f"{last.isoformat()}T16:00:00-05:00"])


def test_calendar_horizon_guard(tmp_path):
    stale = tmp_path / "cal.csv"
    _write_calendar(stale, dt.date.today() + dt.timedelta(days=100))
    with pytest.raises(ValueError, match="less than a year"):
        reference.load_trading_calendar(None, stale)   # never reaches the DB


def test_empty_calendar_rejected(tmp_path):
    empty = tmp_path / "cal.csv"
    empty.write_text("session_seq,session_date,close_time_et,close_at\n")
    with pytest.raises(ValueError, match="no sessions"):
        reference.load_trading_calendar(None, empty)


# ---------------------------------------------------------------------
# reference: page tickers are cleaned, and an override row must be auditable
# ---------------------------------------------------------------------

def test_clean_ticker_drops_page_punctuation_and_keeps_class_dots():
    assert reference._clean_ticker(" iiin} ") == "IIIN"     # the 2018-08-30 S&P 600 page
    assert reference._clean_ticker("BRK.B") == "BRK.B"      # cik_at() maps the dot itself
    assert reference._clean_ticker("BF-B") == "BF-B"
    assert reference._clean_ticker(None) == ""


def _write_overrides(path: Path, rows: list[list[str]]) -> Path:
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["index_name", "ticker", "first_seen", "cik", "source_note"])
        w.writerows(rows)
    return path


def test_read_index_cik_overrides_round_trip(tmp_path):
    path = _write_overrides(tmp_path / "o.csv", [
        ["sp400", " jwa ", "2011-01-27", "107140", "John Wiley class A; see the JW-A run"],
        ["SP600", "QSII", "2018-08-30", "708818", "Quality Systems, renamed NXGN"],
    ])
    rows = reference.read_index_cik_overrides(path)
    assert rows == [
        ("SP400", "JWA", dt.date(2011, 1, 27), 107140, "John Wiley class A; see the JW-A run"),
        ("SP600", "QSII", dt.date(2018, 8, 30), 708818, "Quality Systems, renamed NXGN"),
    ]


@pytest.mark.parametrize("row, message", [
    (["SP400", "JWA", "2011-01-27", "107140", ""], "source_note is empty"),
    (["SP400", "JWA", "2011-01-27", "107140", "   "], "source_note is empty"),
    (["SP1000", "JWA", "2011-01-27", "107140", "cited"], "index_name must be"),
    (["SP400", "", "2011-01-27", "107140", "cited"], "ticker is empty"),
    (["SP400", "JWA", "27/01/2011", "107140", "cited"], "line 2"),
    (["SP400", "JWA", "2011-01-27", "0", "cited"], "cik must be positive"),
    (["SP400", "JWA", "2011-01-27", "abc", "cited"], "line 2"),
])
def test_read_index_cik_overrides_rejects_an_unauditable_row(tmp_path, row, message):
    path = _write_overrides(tmp_path / "o.csv", [row])
    with pytest.raises(ValueError, match=message):
        reference.read_index_cik_overrides(path)


def test_read_index_cik_overrides_rejects_a_duplicate_run(tmp_path):
    path = _write_overrides(tmp_path / "o.csv", [
        ["SP400", "JWA", "2011-01-27", "107140", "cited"],
        ["SP400", "jwa", "2011-01-27", "107140", "cited twice"],
    ])
    with pytest.raises(ValueError, match="duplicate run"):
        reference.read_index_cik_overrides(path)


# ---------------------------------------------------------------------
# fetch_ticker_history: normalisation, file handling, no fabricated rows
# ---------------------------------------------------------------------

def test_normalise_handles_both_shapes_and_dots():
    as_dict = {"0": {"cik_str": 1067983, "ticker": "brk.b", "title": "Berkshire"}}
    as_list = [{"cik_str": "320193", "ticker": "AAPL", "title": "Apple"},
               {"cik_str": "x", "ticker": "BAD"},           # dropped
               {"cik_str": 1, "ticker": "", "title": "no"}]  # dropped
    assert fth._normalise(as_dict) == [(1067983, "BRK-B", "Berkshire")]
    assert fth._normalise(as_list) == [(320193, "AAPL", "Apple")]


def test_probes_are_monthly():
    probes = fth._probes()
    assert len(probes) == 12 * len(list(fth.PROBE_YEARS))
    assert probes[0].endswith("0101") and probes[11].endswith("1201")


def _write_history(path: Path, rows: list[tuple]) -> None:
    with fth._open_text(path, "w") as f:
        w = csv.writer(f)
        w.writerow(["cik", "ticker", "title", "observed_on", "source"])
        w.writerows(rows)


@pytest.mark.parametrize("suffix", [".csv", ".csv.gz"])
def test_dedupe_and_purge_round_trip(tmp_path, suffix):
    path = tmp_path / f"h{suffix}"
    _write_history(path, [
        (1, "A", "t", "2020-01-01", "wayback:1"),
        (1, "A", "t", "2020-01-01", "wayback:1"),     # duplicate
        (1, "A", "t", "2026-09-03", "sec_current"),   # the fabricated kind
        (2, "B", "t", "2020-01-01", "wayback:1"),
    ])
    fth._dedupe(path)
    assert fth._completed_sources(path) == {"wayback:1", "sec_current"}
    removed = fth._purge_sources(path, {"sec_current"})
    assert removed == 1
    with fth._open_text(path, "r") as f:
        rows = list(csv.DictReader(f))
    assert len(rows) == 2
    assert {r["source"] for r in rows} == {"wayback:1"}
    if suffix.endswith(".gz"):
        with open(path, "rb") as f:
            assert f.read(2) == b"\x1f\x8b"


def test_fetch_live_returns_none_on_failure(monkeypatch):
    monkeypatch.setenv("SEC_USER_AGENT", "Test <test@example.com>")

    def boom(url, headers=None):
        raise TimeoutError("simulated")
    monkeypatch.setattr(fth, "_get_json", boom)
    assert fth.fetch_live() is None   # and nothing to write, by construction


def test_fetch_live_requires_agent(monkeypatch):
    monkeypatch.delenv("SEC_USER_AGENT", raising=False)
    with pytest.raises(RuntimeError):
        fth.fetch_live()


# ---------------------------------------------------------------------
# check_docs: the regexes see calls, fences and prose, not just backticks
# ---------------------------------------------------------------------

@pytest.mark.parametrize("line,expected", [
    ("SELECT * FROM sec_gold.as_of_snapshot('AAPL', DATE '2015-06-30');",
     ["sec_gold.as_of_snapshot"]),
    ("joins `sec_reference.company_ticker` and sec_silver.universe_sp1500 in prose",
     ["sec_reference.company_ticker", "sec_silver.universe_sp1500"]),
    ("`sec_gold.fact_asof.tradable_from`", ["sec_gold.fact_asof"]),
    ("nothing here", []),
])
def test_dbobj_any_regex(line, expected):
    assert check_docs.RE_DBOBJ_ANY.findall(line) == expected


def test_dbobj_three_part_regex():
    assert check_docs.RE_DBOBJ.findall("`sec_gold.fact_asof.tradable_from`") == [
        "sec_gold.fact_asof.tradable_from"]


def test_cli_regex():
    assert check_docs.RE_CLI.findall("run `uv run dera build-gold --refresh-only` now") == [
        ("build-gold", " --refresh-only")]


# ---------------------------------------------------------------------
# rebuild-reference: refresh only the gold matviews whose inputs changed
# ---------------------------------------------------------------------

def test_refresh_plan_nothing_changed_nothing_refreshed():
    from dera_pipeline import cli
    assert cli.gold_refresh_plan(set()) == []


def test_refresh_plan_crosswalk_change_skips_fact_asof():
    from dera_pipeline import cli
    assert cli.gold_refresh_plan({"company_ticker"}) == [
        "sec_gold.tradable_financials",
        "sec_gold.tradable_financials_pit",
        "sec_gold.share_class_shares",
        "sec_gold.peer_stats",
    ]


def test_refresh_plan_membership_change_refreshes_fact_asof_not_shares():
    from dera_pipeline import cli
    plan = cli.gold_refresh_plan({"index_membership_timeline", "index_membership_latest"})
    assert "sec_gold.fact_asof" in plan
    assert "sec_gold.share_class_shares" not in plan
    assert plan[-1] == "sec_gold.peer_stats"


def test_refresh_plan_mapping_change_refreshes_only_share_classes():
    from dera_pipeline import cli
    assert cli.gold_refresh_plan({"share_class"}) == ["sec_gold.share_class_shares"]


def test_refresh_plan_everything_changed_is_the_full_list_in_order():
    from dera_pipeline import cli
    assert cli.gold_refresh_plan(set(cli.SPINE_TABLES)) == list(cli.GOLD_MATVIEWS)


def test_every_gold_matview_declares_its_inputs():
    from dera_pipeline import cli
    assert set(cli.GOLD_INPUTS) == set(cli.GOLD_MATVIEWS)
    for inputs in cli.GOLD_INPUTS.values():
        for name in inputs:
            assert name in cli.SPINE_TABLES or name in cli.GOLD_MATVIEWS


# ---------------------------------------------------------------------
# fetch_usgaap_cost_elements: the taxonomy parsers
# ---------------------------------------------------------------------

def test_taxonomy_url_naming_changes_in_2022():
    assert fuce.taxonomy_url(2021).endswith("/2021/us-gaap-2021-01-31.zip")
    assert fuce.taxonomy_url(2022).endswith("/2022/us-gaap-2022.zip")


def test_parse_elements_reads_both_quote_styles_and_prefixes():
    xsd = ('<xs:element name="GrossProfit" type="x"/>'
           "<element id='a' name='CostOfRevenue'/>"
           '<xsd:element name="CostOfGoodsSold" />')
    assert fuce.parse_elements(xsd) == {"GrossProfit", "CostOfRevenue", "CostOfGoodsSold"}


def test_parse_calc_arcs_resolves_locator_labels():
    cal = (
        "<link:loc xlink:href='../elts/us-gaap-2024.xsd#us-gaap_GrossProfit' xlink:label='loc_GP' xlink:type='locator'/>"
        "<link:loc xlink:type='locator' xlink:label='loc_COR' xlink:href='x.xsd#us-gaap_CostOfRevenue'/>"
        "<link:calculationArc order='1' weight='-1.0' xlink:from='loc_GP' xlink:to='loc_COR' xlink:type='arc'/>"
        "<link:calculationArc weight='1.0' xlink:from='loc_GP' xlink:to='loc_missing'/>"
    )
    assert fuce.parse_calc_arcs(cal) == [("GrossProfit", "CostOfRevenue", -1.0)]


def test_year_span_and_parse_years():
    assert fuce.year_span({2013, 2011, 2012}) == (2011, 2013, "2011 2012 2013")
    assert fuce.parse_years("2011-2013") == [2011, 2012, 2013]
    assert fuce.parse_years("2020") == [2020]


def test_family_pattern_keeps_cost_elements_and_drops_others():
    for e in ["GrossProfit", "CostOfRevenue", "CostOfGoodsSoldDirectLabor", "CostsAndExpenses", "Revenues"]:
        assert fuce.FAMILY.match(e)
    for e in ["NetIncomeLoss", "OperatingExpenses", "Assets"]:
        assert not fuce.FAMILY.match(e)


# ---------------------------------------------------------------------
# fetch_usgaap_element_docs: schema, labels, calculation descendants
# ---------------------------------------------------------------------

def test_parse_schema_reads_period_type_and_balance():
    xsd = (b"<xs:schema xmlns:xs='http://www.w3.org/2001/XMLSchema' xmlns:xbrli='http://www.xbrl.org/2003/instance'>"
           b"<xs:element name='DebtCurrent' type='xbrli:monetaryItemType' xbrli:balance='credit' xbrli:periodType='instant'/>"
           b"<xs:element name='Revenues' type='xbrli:monetaryItemType' xbrli:balance='credit' xbrli:periodType='duration'/>"
           b"</xs:schema>")
    out = fued.parse_schema(xsd)
    assert out["DebtCurrent"]["period_type"] == "instant" and out["DebtCurrent"]["balance"] == "credit"
    assert out["Revenues"]["period_type"] == "duration"


def test_parse_labels_resolves_locator_arc_and_role():
    xml = (b"<link:linkbase xmlns:link='http://www.xbrl.org/2003/linkbase' xmlns:xlink='http://www.w3.org/1999/xlink'>"
           b"<link:labelLink>"
           b"<link:loc xlink:href='us-gaap.xsd#us-gaap_DebtCurrent' xlink:label='loc_D'/>"
           b"<link:label xlink:label='lab_D' xlink:role='http://www.xbrl.org/2003/role/documentation'>Amount of debt.</link:label>"
           b"<link:label xlink:label='lab_D' xlink:role='http://www.xbrl.org/2003/role/label'>Debt, Current</link:label>"
           b"<link:labelArc xlink:from='loc_D' xlink:to='lab_D'/>"
           b"</link:labelLink></link:linkbase>")
    assert fued.parse_labels(xml, fued.DOC_ROLE) == {"DebtCurrent": "Amount of debt."}
    assert fued.parse_labels(xml, fued.LABEL_ROLE) == {"DebtCurrent": "Debt, Current"}


def test_descendants_stops_at_depth():
    children = {"A": ["B"], "B": ["C"], "C": ["D"]}
    assert fued.descendants(children, ["A"], 2) == {"A", "B", "C"}


# ---------------------------------------------------------------------
# compustat: Compustat-style items from XBRL tags
# ---------------------------------------------------------------------

from dera_pipeline import compustat  # noqa: E402


def _map(tmp_path, rows):
    p = tmp_path / "map.csv"
    with p.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["item", "period", "rule", "variant", "priority", "term", "coefficient", "required", "notes"])
        w.writerows(rows)
    return compustat.load_map(p)


def test_tag_ladder_takes_the_first_priority_with_a_value(tmp_path):
    items = _map(tmp_path, [["x", "instant", "tag", "", "2", "B", "1", "", ""],
                            ["x", "instant", "tag", "", "1", "A", "1", "", ""]])
    assert compustat.resolve_one({"A": 1.0, "B": 2.0}, items) == {"x": 1.0}
    assert compustat.resolve_one({"B": 2.0}, items) == {"x": 2.0}


def test_formula_required_optional_and_at_least_one(tmp_path):
    items = _map(tmp_path, [["seq", "instant", "tag", "", "1", "SE", "1", "", ""],
                            ["pstk", "instant", "tag", "", "1", "PS", "1", "", ""],
                            ["ceq", "instant", "formula", "1", "", "item:seq", "1", "TRUE", ""],
                            ["ceq", "instant", "formula", "1", "", "item:pstk", "-1", "FALSE", ""],
                            ["aco", "instant", "formula", "1", "", "tag:P", "1", "FALSE", ""],
                            ["aco", "instant", "formula", "1", "", "tag:O", "1", "FALSE", ""]])
    assert compustat.resolve_one({"SE": 100.0, "PS": 10.0}, items)["ceq"] == 90.0
    assert compustat.resolve_one({"SE": 100.0}, items)["ceq"] == 100.0       # optional term is zero
    assert "ceq" not in compustat.resolve_one({"PS": 10.0}, items)           # required term missing
    assert "aco" not in compustat.resolve_one({}, items)                     # none present: nothing, not zero
    assert compustat.resolve_one({"O": 3.0}, items)["aco"] == 3.0


def test_filed_tag_beats_formula(tmp_path):
    items = _map(tmp_path, [["che", "instant", "tag", "", "1", "Total", "1", "", ""],
                            ["che", "instant", "formula", "1", "", "tag:Cash", "1", "TRUE", ""]])
    assert compustat.resolve_one({"Total": 5.0, "Cash": 4.0}, items)["che"] == 5.0


def test_cycle_and_unknown_item_are_refused(tmp_path):
    cyc = _map(tmp_path, [["a", "instant", "formula", "1", "", "item:b", "1", "TRUE", ""],
                          ["b", "instant", "formula", "1", "", "item:a", "1", "TRUE", ""]])
    with pytest.raises(ValueError, match="cycle"):
        compustat.evaluation_order(cyc)
    unk = _map(tmp_path, [["a", "instant", "formula", "1", "", "item:zz", "1", "TRUE", ""]])
    with pytest.raises(ValueError, match="unknown item"):
        compustat.evaluation_order(unk)


def test_period_type_must_match_the_taxonomy(tmp_path):
    items = _map(tmp_path, [["x", "instant", "tag", "", "1", "Revenues", "1", "", ""]])
    probs = compustat.validate(items, {"Revenues": {"period_type": "duration"}})
    assert probs and "duration" in probs[0]


def test_a_row_with_an_unquoted_comma_is_refused(tmp_path):
    p = tmp_path / "map.csv"
    p.write_text("item,period,rule,variant,priority,term,coefficient,required,notes\n"
                 "x,instant,tag,,1,A,1,,a note, with a comma\n")
    with pytest.raises(ValueError, match="more fields"):
        compustat.load_map(p)


def test_the_shipped_map_is_sound():
    items = compustat.load_map()
    assert compustat.validate(items, compustat.load_element_docs()) == []
    q = {r["base_item"] for r in compustat.load_quarterly()}
    assert q <= set(items)


# ---------------------------------------------------------------------------- footnote items
from dera_pipeline import notes_items as ni  # noqa: E402


@pytest.mark.parametrize("segments,scope", [
    ("", "none"),
    ("RetirementPlanType=PensionPlansDefinedBenefit;", "total"),
    ("DefinedBenefitPlansDisclosuresDefinedBenefitPlans=PensionPlansDefinedBenefit;", "total"),
    ("RetirementPlanSponsorLocation=Foreign;RetirementPlanType=PensionPlansDefinedBenefit;", "foreign"),
    ("RetirementPlanSponsorLocation=US;RetirementPlanType=PensionPlan;", "domestic"),
    ("DefinedBenefitPlansDisclosuresDefinedBenefitPlans=UnitedStatesPensionPlansOfUSEntityDefinedBenefit;", "domestic"),
    ("RetirementPlanType=OtherPostretirementBenefitPlansDefinedBenefit;", "opeb"),
    ("RetirementPlanType=SomeCustomPlan;", "plan_other"),
    ("RetirementPlanSponsorLocation=US;", "detail"),        # location alone: plan type unknown
    ("DefinedBenefitPlanByPlanAssetCategories=EquitySecurities;RetirementPlanType=PensionPlansDefinedBenefit;",
     "detail"),
])
def test_pension_scope(segments, scope):
    assert ni.pension_scope(segments) == scope


def test_select_pension_priority():
    assert ni.select_pension({"total": 10.0, "domestic": 6.0, "foreign": 4.0, "none": 12.0}, True) == (10.0, "pension_total")
    # assets tagged by location only, the obligation as a total and by location: both use dom_plus_for
    assets = ni.pension_candidates({"domestic": 6.0, "foreign": 4.0}, True)
    pbo = ni.pension_candidates({"total": 15.0, "domestic": 9.0, "foreign": 6.0}, True)
    assert ni.common_rule(assets, pbo) == "dom_plus_for"
    assert ni.common_rule(ni.pension_candidates({"foreign": 4.0}, True), pbo) == ""
    assert ni.select_pension({"domestic": 6.0, "foreign": 4.0}, True) == (10.0, "dom_plus_for")
    assert ni.select_pension({"foreign": 4.0}, True) == (4.0, "one_location")
    assert ni.select_pension({"foreign": 4.0, "none": 23.0}, True) == (4.0, "one_location")
    assert ni.select_pension({"none": 12.0}, False) == (12.0, "undimensioned")
    # an undimensioned figure beside OPEB members may include OPEB: nothing, not a guess
    assert ni.select_pension({"none": 12.0}, True) == (None, "")
    # a single location beside an undimensioned total is part of it
    assert ni.select_pension({"foreign": 4.0, "none": 23.0}, False) == (23.0, "undimensioned")


@pytest.mark.parametrize("member,words", [
    ("WalMartStoresInc", "Wal Mart Stores Inc"), ("ATTInc", "ATT Inc"), ("CustomerA", "Customer A"),
    ("RJRTobacco", "RJR Tobacco"), ("", ""),
])
def test_camel_words(member, words):
    assert ni.camel_words(member) == words


def test_sin_codes():
    assert ni.sin_codes("Smokeless Products") == (2111, None)
    assert ni.sin_codes("Beer") == (2082, None)
    assert ni.sin_codes("Wine And Spirits") == (2084, None)
    assert ni.sin_codes("Las Vegas Casinos") == (None, 713210)
    assert ni.sin_codes("Gaming") == (None, None)            # AMD's video-game segment is not gambling
    assert ni.sin_codes("Data Center") == (None, None)


@pytest.mark.parametrize("name,ctype", [
    ("Walmart Inc", "COMPANY"), ("Customer A", "UNKNOWN"), ("Top Ten Customers", "UNKNOWN"),
    ("Second Largest Customer", "UNKNOWN"), ("Medicare", "GOVERNMENT"), ("United States Government", "GOVERNMENT"),
    ("Home Depot Inc", "COMPANY"), ("", "UNKNOWN"),
])
def test_customer_type(name, ctype):
    assert ni.customer_type(name) == ctype


def test_aoci_component():
    assert ni.aoci_component("AccumulatedOtherComprehensiveIncomeLossForeignCurrencyTranslationAdjustmentNetOfTax", "") \
        == ("recta", "element")
    assert ni.aoci_component("AccumulatedOtherComprehensiveIncomeLossNetOfTax",
                             "EquityComponents=AccumulatedNetUnrealizedInvestmentGainLoss;") == ("msa", "component_axis")
    # hedging reserves are not MSA (S&P excludes SFAS 133 adjustments); the AOCI total is neither item
    assert ni.aoci_component("AccumulatedOtherComprehensiveIncomeLossNetOfTax",
                             "EquityComponents=AccumulatedGainLossNetCashFlowHedgeParent;") == (None, "")
    assert ni.aoci_component("AccumulatedOtherComprehensiveIncomeLossNetOfTax", "") == (None, "")
    assert ni.aoci_component("AccumulatedOtherComprehensiveIncomeLossNetOfTax",
                             "ConsolidatedEntities=ParentCompany;EquityComponents=AccumulatedTranslationAdjustment;") \
        == (None, "")


# ---------------------------------------------------------------------------- presentation rules
def test_presentation_rules_load_and_cover_known_items():
    rules = compustat.load_presentation_rules()
    items = compustat.load_map()
    assert {r["item"] for r in rules} <= set(items)
    assert all(r["tag"] in items for r in rules if r["rule"] == "zero_if_zero")
    assert {r["rule"] for r in rules} <= compustat.PRESENTATION_RULE_KINDS


def _rule(**kw):
    import re
    base = {"item": "dltt", "rule": "zero", "statements": {"BS"}, "tag": "", "label": re.compile("debt|notes?", re.I),
            "exclude": re.compile(r"receivable|\bnotes? \d", re.I)}
    return base | kw


def test_zero_needs_the_statement_and_no_family_line():
    r = _rule()
    fam = {"LongTermDebtNoncurrent"}
    assert compustat.zero_allowed([("BS", "Assets", "Total assets"), ("BS", "Liabilities", "Total liabilities")], r, fam)
    # a debt line with an unmapped tag: unknown, not zero
    assert not compustat.zero_allowed([("BS", "Assets", "Total assets"), ("BS", "Custom1", "Senior notes")], r, fam)
    # a mapped tag present
    assert not compustat.zero_allowed([("BS", "LongTermDebtNoncurrent", "LTD")], r, fam)
    # an excluded label (an asset, a note reference) is not evidence of debt
    assert compustat.zero_allowed([("BS", "Custom2", "Notes receivable"), ("BS", "Custom3", "Commitments (Note 9)")], r, fam)
    # no balance sheet presented at all: unknown
    assert not compustat.zero_allowed([("IS", "Revenues", "Revenue")], r, fam)


def test_label_rule_matches_only_its_tag_and_statement():
    import re
    r = _rule(rule="refuse_tag", statements={"IS"}, tag="Revenues", label=re.compile("other income", re.I))
    assert compustat.label_matches([("IS", "Revenues", "Total revenues and other income")], r)
    assert not compustat.label_matches([("IS", "Revenues", "Total revenues")], r)
    assert not compustat.label_matches([("BS", "Revenues", "Total revenues and other income")], r)


def test_family_tags_follow_helper_items():
    items = compustat.load_map()
    fam = compustat.family_tags(items, "dlc")
    assert {"DebtCurrent", "LongTermDebtCurrent", "ShortTermBorrowings"} <= fam


def test_revenues_including_other_income_is_detected():
    import pandas as pd
    f = pd.DataFrame({"Revenues": [413680.0, 383285.0, 100.0],
                      "RevenueFromContractWithCustomerIncludingAssessedTax": [398675.0, None, 100.0],
                      "RevenueFromContractWithCustomerExcludingAssessedTax": [None, 383285.0, None],
                      "IncomeLossFromEquityMethodInvestments": [11463.0, None, 0.0],
                      "OtherNonoperatingIncomeExpense": [3542.0, 5.0, None]})
    comps = {"IncomeLossFromEquityMethodInvestments", "OtherNonoperatingIncomeExpense"}
    # XOM-like: sales + equity income + other income = Revenues; Apple-like and zero-component rows are not
    assert compustat.revenues_include_nonoperating(f, comps).tolist() == [True, False, False]
