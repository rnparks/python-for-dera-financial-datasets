"""Unit tests for the two filing-driven reference tools.

No network, no database: the parsers are exercised on small fixtures
shaped like the real documents, and the resolution rules on plain
inputs. The end-to-end behaviour is covered by `dera verify` against the
live data.
"""

from __future__ import annotations

import sys

import pytest

from dera_pipeline import config

sys.path.insert(0, str(config.PROJECT_ROOT / "tools"))
import fetch_cover_page_classes as cover  # noqa: E402
import fetch_sp500_history as hist  # noqa: E402

# ---------------------------------------------------------------------
# fetch_cover_page_classes: inline-XBRL cover parsing and resolution
# ---------------------------------------------------------------------

IXBRL = b"""<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"
      xmlns:ix="http://www.xbrl.org/2013/inlineXBRL"
      xmlns:xbrli="http://www.xbrl.org/2003/instance"
      xmlns:xbrldi="http://xbrl.org/2006/xbrldi">
<body>
<ix:header><ix:resources>
  <xbrli:context id="c-1"><xbrli:entity><xbrli:identifier scheme="s">1</xbrli:identifier></xbrli:entity></xbrli:context>
  <xbrli:context id="c-2"><xbrli:entity><xbrli:identifier scheme="s">1</xbrli:identifier>
    <xbrli:segment><xbrldi:explicitMember dimension="us-gaap:StatementClassOfStockAxis">us-gaap:CommonClassAMember</xbrldi:explicitMember></xbrli:segment>
  </xbrli:entity></xbrli:context>
  <xbrli:context id="c-3"><xbrli:entity><xbrli:identifier scheme="s">1</xbrli:identifier>
    <xbrli:segment><xbrldi:explicitMember dimension="us-gaap:StatementClassOfStockAxis">acme:ClassBUnlistedMember</xbrldi:explicitMember></xbrli:segment>
  </xbrli:entity></xbrli:context>
</ix:resources></ix:header>
<p><ix:nonNumeric name="dei:Security12bTitle" contextRef="c-2">Class A Common Stock</ix:nonNumeric>
   <ix:nonNumeric name="dei:TradingSymbol" contextRef="c-2">ACM.E</ix:nonNumeric>
   <ix:nonNumeric name="dei:SecurityExchangeName" contextRef="c-2">NYSE</ix:nonNumeric></p>
<p><ix:nonNumeric name="dei:Security12bTitle" contextRef="c-3">Class B Common Stock</ix:nonNumeric>
   <ix:nonNumeric name="dei:NoTradingSymbolFlag" contextRef="c-3">true</ix:nonNumeric></p>
<p><ix:nonNumeric name="dei:Security12bTitle" contextRef="c-1">4.5% Notes due 2030</ix:nonNumeric>
   <ix:nonNumeric name="dei:TradingSymbol" contextRef="c-1">ACM30</ix:nonNumeric></p>
</body></html>"""


def test_parse_cover_dimensioned_undimensioned_and_unlisted():
    rows = {r["class_member"] or "__default__": r for r in cover.parse_cover(IXBRL)}
    assert rows["CommonClassA"]["trading_symbol"] == "ACM-E"     # dot -> hyphen
    assert rows["CommonClassA"]["exchange"] == "NYSE"
    assert rows["ClassBUnlisted"]["trading_symbol"] == ""         # NoTradingSymbolFlag
    assert rows["__default__"]["trading_symbol"] == "ACM30"       # undimensioned note line


def test_member_label_strips_prefix_and_suffix():
    assert cover._member_label("us-gaap:CommonClassAMember") == "CommonClassA"
    assert cover._member_label("meta:ClassBCommonStockMember") == "ClassBCommonStock"
    assert cover._member_label("acme:Weird") == "Weird"


@pytest.mark.parametrize("title,members,expected", [
    ("Class A Common Stock, $0.000006 par value", {"CommonClassA", "CommonClassB"}, "CommonClassA"),
    ("Class B Common Stock", {"CommonClassA", "CommonClassB"}, "CommonClassB"),
    ("Class A Common Stock", {"CommonClassA", "CommonClassA1", "CommonClassA2"}, "CommonClassA"),
    ("Common Stock — par value $0.01", {"CommonClassA", "CommonClassB", "CommonStock"}, "CommonStock"),
    ("Common Stock", {"CommonClassA", "CommonClassB"}, None),          # ambiguous: not guessed
    ("Common Stock", {"VotingCommonStock", "NonvotingCommonStock"}, None),
    ("Common Stock", {"OnlyMember"}, "OnlyMember"),
    ("4.5% Notes due 2030", {"CommonClassA", "CommonClassB"}, None),
])
def test_match_title_to_member(title, members, expected):
    assert cover.match_title_to_member(title, members) == expected


# ---------------------------------------------------------------------
# fetch_sp500_history: constituents table parsing and probes
# ---------------------------------------------------------------------

def _table(rows: list[tuple], header: tuple, table_id: str | None = None) -> str:
    attrs = f' id="{table_id}"' if table_id else ""
    head = "".join(f"<th>{h}</th>" for h in header)
    body = "".join(
        "<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in rows)
    return f"<table{attrs} class='wikitable'><tr>{head}</tr>{body}</table>"


def test_parse_constituents_reads_cik_column_and_href_cik():
    header = ("Symbol", "Security", "SEC filings", "GICS Sector", "GICS Sub-Industry",
              "Headquarters", "Date added", "CIK")
    rows = [("MMM", "3M", '<a href="https://www.sec.gov/cgi-bin/browse-edgar?CIK=66740">reports</a>',
             "Industrials", "Industrial Conglomerates", "St Paul", "1957-03-04", "66740")]
    rows += [(f"T{i}", f"Co {i}", "reports", "Energy", "Oil", "X", "", str(1000 + i))
             for i in range(320)]
    html = "<html><body>" + _table(rows, header, "constituents") + "</body></html>"
    out = hist.parse_constituents(html)
    assert len(out) == 321
    first = out[0]
    assert first["ticker"] == "MMM" and first["cik"] == "66740"
    assert first["gics_sector"] == "Industrials" and first["date_added"] == "1957-03-04"


def test_parse_constituents_pre2014_shape_has_no_cik_but_is_recorded():
    header = ("Ticker symbol", "Company", "SEC filings", "GICS Sector", "Address of Headquarters")
    rows = [("BRK.B", "Berkshire", '<a href="?CIK=BRK.B">reports</a>', "Financials", "Omaha")]
    rows += [(f"T{i}", f"Co {i}", "reports", "Energy", "X") for i in range(310)]
    out = hist.parse_constituents("<html><body>" + _table(rows, header) + "</body></html>")
    assert out[0]["ticker"] == "BRK-B" and out[0]["cik"] == ""
    assert out[0]["gics_sub_industry"] == "" and out[0]["date_added"] == ""


def test_parse_constituents_ignores_small_tables():
    header = ("Symbol", "Security")
    rows = [(f"T{i}", f"Co {i}") for i in range(40)]   # the "changes" table shape
    assert hist.parse_constituents("<html><body>" + _table(rows, header) + "</body></html>") == []


def test_probes_are_monthly_from_2008():
    probes = hist._probes()
    assert probes[0] == "2008-10-01T00:00:00Z"
    assert probes[1] == "2008-11-01T00:00:00Z"
    assert all(p.endswith("-01T00:00:00Z") for p in probes)
