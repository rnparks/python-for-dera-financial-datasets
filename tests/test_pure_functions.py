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
