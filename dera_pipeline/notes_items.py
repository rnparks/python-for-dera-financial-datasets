"""Compustat footnote items from the SEC Financial Statement and Notes facts.

Pure functions; tools/export_notes_items.py applies them to
data/exports/notes/notes_facts.parquet (tools/extract_notes_facts.py).
docs/compustat_items.md ("Footnote items") states the rules and the
evidence for each.

Pensions (Compustat aco_pnfnda). S&P's definitions (Compustat User's
Guide 8/2003, ch. 5): since SFAS 132 (fiscal years from 1998) Compustat no
longer splits over- and underfunded plans, so pplao ("Pension Plan
Assets") is the fair value of all defined-benefit pension plan assets and
pbpro ("Pension - Projected Benefit Obligation") the PBO of all
defined-benefit pension plans, foreign plans included (footnote IK). Other
postretirement (OPEB) plans are excluded. A filing's pension total is
chosen by an allowlist of dimension members, never by pattern:

    1. pension_total   the plan-type axis alone, on a pension member
    2. dom_plus_for    domestic + foreign pension members, both present
    3. one_location    only a domestic or only a foreign pension member
    4. undimensioned   the undimensioned fact, only when the filing tags
                       no plan type at all for that element (with OPEB
                       members present the undimensioned figure is
                       sometimes the pension plan, sometimes pension plus
                       OPEB: measured, see the docs)
"""
from __future__ import annotations

import re

PLAN_AXES = ("DefinedBenefitPlansDisclosuresDefinedBenefitPlans", "RetirementPlanType")
LOCATION_AXIS = "RetirementPlanSponsorLocation"
PENSION_TOTAL = {"PensionPlansDefinedBenefit", "PensionPlan", "DefinedBenefitPensionPlan"}
PENSION_DOMESTIC = {"UnitedStatesPensionPlansOfUSEntityDefinedBenefit"}
PENSION_FOREIGN = {"ForeignPensionPlansDefinedBenefit"}
LOCATION_DOMESTIC = {"Domestic", "DomesticPlan", "US", "UnitedStates"}
LOCATION_FOREIGN = {"Foreign", "ForeignPlan", "NonUs"}
OPEB = {"OtherPostretirementBenefitPlansDefinedBenefit", "OtherPostretirementBenefitPlan",
        "UnitedStatesPostretirementBenefitPlansOfUSEntityDefinedBenefit",
        "ForeignPostretirementBenefitPlansDefinedBenefit", "DefinedBenefitPostretirementHealthCoverage",
        "DefinedBenefitPostretirementLifeInsurance"}
RULE_ORDER = ["pension_total", "dom_plus_for", "one_location", "undimensioned"]


def parse_segments(segments: str) -> dict[str, str]:
    """'A=x;B=y;' (dim.tsv's segments) -> {'A': 'x', 'B': 'y'}; '' -> {}."""
    out = {}
    for part in (segments or "").strip(";").split(";"):
        if "=" in part:
            axis, member = part.split("=", 1)
            out[axis] = member
    return out


def pension_scope(segments: str) -> str:
    """Classify one fact's dimensions for pension totals:
    'none' (undimensioned), 'total', 'domestic', 'foreign' (pension plans),
    'opeb', 'plan_other' (some other plan-type member), or 'detail'
    (any other axis: asset categories, fair-value levels, plan names)."""
    d = parse_segments(segments)
    if not d:
        return "none"
    plan = [d[a] for a in PLAN_AXES if a in d]
    loc = d.get(LOCATION_AXIS)
    if set(d) - set(PLAN_AXES) - {LOCATION_AXIS} or len(plan) > 1:
        return "detail"
    if not plan:
        return "detail"                       # location alone: pension and OPEB together or apart, unknown
    m = plan[0]
    if m in OPEB:
        return "opeb"
    if m in PENSION_DOMESTIC:
        return "domestic" if loc is None else "detail"
    if m in PENSION_FOREIGN:
        return "foreign" if loc is None else "detail"
    if m in PENSION_TOTAL:
        if loc is None:
            return "total"
        if loc in LOCATION_DOMESTIC:
            return "domestic"
        if loc in LOCATION_FOREIGN:
            return "foreign"
        return "detail"
    return "plan_other"


def select_pension(values: dict[str, float], plan_typed: bool) -> tuple[float | None, str]:
    """One filing's pension total for one element.

    values: scope -> value for the scopes present ('none', 'total',
    'domestic', 'foreign'); plan_typed: the filing tags any plan-type member
    (pension, OPEB or other) on this element. Returns (value, rule)."""
    if "total" in values:
        return values["total"], "pension_total"
    if "domestic" in values and "foreign" in values:
        return values["domestic"] + values["foreign"], "dom_plus_for"
    if "domestic" in values or "foreign" in values:
        return values.get("domestic", values.get("foreign")), "one_location"
    if "none" in values and not plan_typed:
        return values["none"], "undimensioned"
    return None, ""


def camel_words(member: str) -> str:
    """'WalMartStoresInc' -> 'Wal Mart Stores Inc'; 'ATTInc' -> 'ATT Inc';
    'ProfessionalEmployeeOrganizationServicesSegment' -> '... Services Segment'."""
    s = re.sub(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])", " ", member or "")
    return re.sub(r"\s+", " ", s).strip()


# Sin-industry segments (sinAlgo). Compustat assigns each segment a SIC (sics1) and NAICS (naicsh);
# XBRL segment members carry only a name, so the codes CZ tests are assigned from the name. Each
# entry: (pattern on the camel-split member name, sics1, naicsh). Bare "gaming" is excluded: it names
# video-game segments (AMD's Gaming segment) as often as gambling.
SIN_SEGMENTS = [
    (r"\b(tobacco|cigarettes?|cigars?|smokeless|smokeable|smoke free|snus|nicotine|e ?vapor)\b", 2111, None),
    (r"\b(beers?|brew(s|ing|ery|eries)?|malt beverages?)\b", 2082, None),
    (r"\b(wines?|winery|wineries)\b", 2084, None),
    (r"\b(spirits|distill(ed|ery|eries|ing)?|liquors?|whisk(e)?y|vodka|bourbon)\b", 2085, None),
    (r"\b(casinos?|wagering|betting|lotter(y|ies)|racinos?|race ?tracks?|pari ?mutuel|sportsbook)\b",
     None, 713210),
]


def sin_codes(name: str) -> tuple[int | None, int | None]:
    """(sics1, naicsh) for a segment name matching SIN_SEGMENTS, else (None, None)."""
    text = (name or "").lower()
    for pattern, sic, naics in SIN_SEGMENTS:
        if re.search(pattern, text):
            return sic, naics
    return None, None


# Major-customer members that name no company (CustomerMomentum matches customer names to company
# names, so these could only produce false matches). Compustat's ctype distinguishes COMPANY from
# GOVERNMENT, MARKET and the like; anything here is not COMPANY.
GENERIC_CUSTOMER = re.compile(
    r"^(customers?|clients?|vendors?|suppliers?|distributors?|resellers?|partners?|payors?|purchasers?|"
    r"one|two|three|four|five|six|seven|eight|nine|ten|first|second|third|fourth|fifth|top|largest|"
    r"major|significant|other|others|all|no|external|single|individual|commercial|residential|"
    r"industrial|wholesale|retail|government|governmental|federal|state|us|u s|medicare|medicaid|"
    r"military|department|international|domestic|foreign|related|affiliated?)\b|"
    r"\b(customers?|clients?|vendors?|suppliers?|distributors?)( [a-z0-9]{1,2}| one| two| three| four| five)?$",
    re.IGNORECASE)
GOVERNMENT_CUSTOMER = re.compile(
    r"\b(government|governmental|federal|medicare|medicaid|department of|military|army|navy|air force|"
    r"state of|county|municipal|agency)\b", re.IGNORECASE)


def customer_type(name: str) -> str:
    """Compustat-style ctype for a camel-split customer member name."""
    if GOVERNMENT_CUSTOMER.search(name or ""):
        return "GOVERNMENT"
    if not name or GENERIC_CUSTOMER.search(name):
        return "UNKNOWN"
    return "COMPANY"
