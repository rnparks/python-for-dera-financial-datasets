"""Compustat-style items from XBRL facts, by the rules in data/reference/compustat_item_map.csv.

WHY. Published cross-sectional predictors (Chen-Zimmermann, Novy-Marx, ...) are
defined over Compustat items -- AT, CEQ, DLC, XSGA -- and S&P's definition of an
item is not the same as any one XBRL tag: DLC is the current portion of
long-term debt plus short-term notes, XSGA includes research and development,
COGS excludes depreciation. The map states, per item, a ladder of tags (first
with a value wins) and formula variants over other items, each row citing the
S&P and FASB definitions it rests on. This module validates the map and
evaluates it; it has no database access, so the rules are unit-tested.

RULES
  - An item resolves from its tag ladder first: the lowest-priority-number tag
    with a value. A filed figure always beats a reconstruction.
  - Otherwise its formula variants are tried in order. A variant needs every
    required term; optional terms count as zero; and at least one term must be
    present, so a company with none of the parts gets nothing, not zero.
  - A formula term is a tag ("tag:X") or another item ("item:Y"). Items may
    depend on items, in any order the map is written, as long as there is no
    cycle; validate() refuses a cycle, an unknown item and a tag whose FASB
    period type differs from the item's.
  - Items whose name starts with "_" are helpers: resolved, never exported.
"""
from __future__ import annotations

import csv
from collections import defaultdict
from dataclasses import dataclass, field
from pathlib import Path

import pandas as pd

from dera_pipeline import config

MAP_PATH = config.PROJECT_ROOT / "data" / "reference" / "compustat_item_map.csv"
QUARTERLY_PATH = config.PROJECT_ROOT / "data" / "reference" / "compustat_quarterly_items.csv"
DOCS_PATH = config.PROJECT_ROOT / "data" / "reference" / "usgaap_element_docs.csv"


@dataclass
class Item:
    name: str
    period: str                                   # 'instant' or 'duration'
    tags: list[tuple[int, str, int]] = field(default_factory=list)          # (priority, tag, sign)
    variants: dict[int, list[tuple[str, int, bool]]] = field(default_factory=dict)  # variant -> [(term, coef, required)]

    def dependencies(self) -> set[str]:
        return {t[5:] for terms in self.variants.values() for t, _, _ in terms if t.startswith("item:")}

    def tags_used(self) -> set[str]:
        out = {t for _, t, _ in self.tags}
        out |= {t[4:] for terms in self.variants.values() for t, _, _ in terms if t.startswith("tag:")}
        return out


def load_map(path: Path = MAP_PATH) -> dict[str, Item]:
    items: dict[str, Item] = {}
    with Path(path).open() as f:
        for r in csv.DictReader(f):
            if None in r:  # an unquoted comma in a note shifts every field after it
                raise ValueError(f"{path}: row for {r['item']} has more fields than the header")
            it = items.setdefault(r["item"], Item(r["item"], r["period"]))
            if it.period != r["period"]:
                raise ValueError(f"{r['item']}: rows disagree on period type")
            coef = int(r["coefficient"] or 1)
            if r["rule"] == "tag":
                it.tags.append((int(r["priority"]), r["term"], coef))
            elif r["rule"] == "formula":
                it.variants.setdefault(int(r["variant"]), []).append(
                    (r["term"], coef, r["required"].strip().upper() == "TRUE"))
            else:
                raise ValueError(f"{r['item']}: unknown rule {r['rule']!r}")
    for it in items.values():
        it.tags.sort()
    return items


def evaluation_order(items: dict[str, Item]) -> list[str]:
    """Items ordered so every item comes after the items its formulas use."""
    order, state = [], {}

    def visit(n, path):
        if state.get(n) == "done":
            return
        if state.get(n) == "active":
            raise ValueError(f"cycle in compustat_item_map: {' -> '.join(path + [n])}")
        state[n] = "active"
        for d in sorted(items[n].dependencies()):
            if d not in items:
                raise ValueError(f"{n}: formula uses unknown item {d!r}")
            visit(d, path + [n])
        state[n] = "done"
        order.append(n)

    for n in sorted(items):
        visit(n, [])
    return order


def validate(items: dict[str, Item], element_docs: dict[str, dict] | None = None) -> list[str]:
    """Problems with the map, empty when it is sound. Raises on a cycle or unknown item."""
    evaluation_order(items)
    problems = []
    for it in items.values():
        if not it.tags and not it.variants:
            problems.append(f"{it.name}: no rule")
        for v, terms in it.variants.items():
            if not terms:
                problems.append(f"{it.name}: variant {v} has no terms")
        if element_docs is not None:
            for t in sorted(it.tags_used()):
                d = element_docs.get(t)
                if d is None:
                    problems.append(f"{it.name}: tag {t} is not in the US-GAAP taxonomy 2011-2026")
                elif d["period_type"] != it.period:
                    problems.append(f"{it.name}: tag {t} is {d['period_type']}, item is {it.period}")
    return problems


def load_element_docs(path: Path = DOCS_PATH) -> dict[str, dict]:
    with Path(path).open() as f:
        return {r["element"]: r for r in csv.DictReader(f)}


def resolve_frame(tags: pd.DataFrame, items: dict[str, Item]) -> pd.DataFrame:
    """
    tags: one row per evaluation unit (index), one column per XBRL tag, NaN where not filed.
    Returns one column per item (helpers included), same index.
    """
    out = pd.DataFrame(index=tags.index)

    def col(name):
        return tags[name] if name in tags else pd.Series(float("nan"), index=tags.index)

    for n in evaluation_order(items):
        it = items[n]
        value = pd.Series(float("nan"), index=tags.index)
        for _, t, sign in it.tags:
            value = value.combine_first(col(t) * sign)
        for v in sorted(it.variants):
            total = pd.Series(0.0, index=tags.index)
            ok = pd.Series(True, index=tags.index)
            present = pd.Series(0, index=tags.index)
            for term, coef, required in it.variants[v]:
                x = out[term[5:]] if term.startswith("item:") else col(term[4:])
                if required:
                    ok &= x.notna()
                present += x.notna().astype(int)
                total += coef * x.fillna(0.0)
            variant_value = total.where(ok & (present > 0))
            value = value.combine_first(variant_value)
        out[n] = value
    return out


def resolve_one(values: dict[str, float], items: dict[str, Item]) -> dict[str, float]:
    """Single-company convenience wrapper over resolve_frame (used by tests and spot checks)."""
    frame = pd.DataFrame([values]) if values else pd.DataFrame(index=[0])
    res = resolve_frame(frame, items).iloc[0]
    return {k: v for k, v in res.items() if pd.notna(v)}


def load_quarterly(path: Path = QUARTERLY_PATH) -> list[dict]:
    with Path(path).open() as f:
        return list(csv.DictReader(f))


def exported(items: dict[str, Item]) -> list[str]:
    return sorted(n for n in items if not n.startswith("_"))


def item_users(items: dict[str, Item]) -> dict[str, set[str]]:
    """item -> items whose formulas use it (for impact analysis of a mapping change)."""
    users = defaultdict(set)
    for it in items.values():
        for d in it.dependencies():
            users[d].add(it.name)
    return users
