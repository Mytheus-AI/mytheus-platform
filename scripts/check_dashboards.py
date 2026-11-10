#!/usr/bin/env python3
"""Structural check of the provisioned Grafana dashboards (stdlib only; run by
scripts/check-observability.sh and CI).

For every observability/grafana/dashboards/*.json: valid JSON; a unique uid and a title; unique
panel ids; every panel has a gridPos inside the 24-column grid; every non-row panel has at least
one target with a non-empty expr, on the provisioned Prometheus datasource (uid `prometheus`);
every `$variable` an expr or title uses is defined in templating; a repeated row repeats over a
defined variable. Exits 1 with one line per problem.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DASHBOARDS = ROOT / "observability" / "grafana" / "dashboards"
DATASOURCE_UID = "prometheus"
BUILTIN = {"__range", "__interval", "__rate_interval", "__all", "__name", "__range_s"}
VAR = re.compile(r"\$(\w+)|\$\{(\w+)")


def check(path: Path, uids: dict[str, Path]) -> list[str]:
    where = path.name
    try:
        dash = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as exc:
        return [f"{where}: invalid JSON: {exc}"]
    problems: list[str] = []
    uid, title = dash.get("uid"), dash.get("title")
    if not uid or not title:
        problems.append(f"{where}: uid and title are required")
    elif uid in uids:
        problems.append(f"{where}: uid {uid!r} also used by {uids[uid].name}")
    else:
        uids[uid] = path
    defined = {v.get("name") for v in (dash.get("templating") or {}).get("list", [])}
    ids: set[int] = set()
    for panel in dash.get("panels", []):
        pid = panel.get("id")
        name = f"{where} panel {pid} {panel.get('title')!r}"
        if not isinstance(pid, int) or pid in ids:
            problems.append(f"{name}: missing or duplicate id")
        ids.add(pid)
        grid = panel.get("gridPos") or {}
        if not all(isinstance(grid.get(k), int) for k in ("x", "y", "w", "h")):
            problems.append(f"{name}: gridPos needs integer x, y, w, h")
        elif grid["x"] + grid["w"] > 24:
            problems.append(f"{name}: gridPos wider than the 24-column grid")
        used = {a or b for a, b in VAR.findall(str(panel.get("title", "")))}
        if panel.get("type") == "row":
            if panel.get("repeat") and panel["repeat"] not in defined:
                problems.append(f"{name}: repeats over undefined variable {panel['repeat']!r}")
        else:
            targets = panel.get("targets") or []
            if not targets:
                problems.append(f"{name}: no targets")
            ds = (panel.get("datasource") or {}).get("uid")
            if ds != DATASOURCE_UID:
                problems.append(f"{name}: datasource uid {ds!r}, expected {DATASOURCE_UID!r}")
            for t in targets:
                expr = str(t.get("expr") or "").strip()
                if not expr:
                    problems.append(f"{name}: target {t.get('refId')} has no expr")
                if expr.count("(") != expr.count(")") or expr.count("{") != expr.count("}"):
                    problems.append(f"{name}: target {t.get('refId')} has unbalanced brackets")
                used |= {a or b for a, b in VAR.findall(expr)}
        for var in used - defined - BUILTIN:
            problems.append(f"{name}: uses undefined variable ${var}")
    return problems


def main() -> int:
    uids: dict[str, Path] = {}
    problems: list[str] = []
    files = sorted(DASHBOARDS.glob("*.json"))
    for path in files:
        problems += check(path, uids)
    for line in problems:
        print(line, file=sys.stderr)
    if not problems:
        print(f"dashboards OK: {len(files)} files")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
