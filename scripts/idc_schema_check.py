#!/usr/bin/env python3
"""idc_schema_check.py — the mechanical issue-body schema check (`WORKFLOW.md §3.2`).

Plan runs this on every issue body before board admission: an issue is the glass-wall
contract a builder works cold, so it must carry the full 6-element goal contract plus
declared boundaries, dependencies, and trace. This is a lean guardrail — it checks
structure and non-emptiness, not prose quality.

Required labels (each on its own line, as written): GOAL, VERIFICATION SURFACE, CONSTRAINTS,
BOUNDARIES, ITERATION POLICY, BLOCKED-STOP, ASSUMPTIONS, Dependencies, Trace. Additionally:
GOAL and VERIFICATION SURFACE must be non-empty, and BOUNDARIES must declare both `touch`
and `off-limits` (the deconfliction output).

Usage: idc_schema_check.py <issue-body.md>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import re
import sys

REQUIRED = [
    "GOAL", "VERIFICATION SURFACE", "CONSTRAINTS", "BOUNDARIES",
    "ITERATION POLICY", "BLOCKED-STOP", "ASSUMPTIONS", "Dependencies", "Trace",
]


def value_after(text, label):
    m = re.search(rf"^{re.escape(label)}:[ \t]*(.*)$", text, re.M)
    return (m.group(1).strip() if m else None)


def check(text):
    problems = []
    for label in REQUIRED:
        if not re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(f"missing `{label}:` element")
    goal = value_after(text, "GOAL")
    if goal is not None and not goal:
        problems.append("`GOAL:` is empty (needs a single observable end-state)")
    vs = value_after(text, "VERIFICATION SURFACE")
    if vs is not None and not vs:
        problems.append("`VERIFICATION SURFACE:` is empty (needs runnable commands + what passing looks like)")
    bnd = re.search(r"^BOUNDARIES:.*$", text, re.M)
    if bnd:
        line = bnd.group(0)
        if "touch" not in line.lower():
            problems.append("`BOUNDARIES:` must declare `touch` (in-scope surfaces)")
        if "off-limits" not in line.lower():
            problems.append("`BOUNDARIES:` must declare `off-limits` (out-of-scope surfaces)")
    return problems


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: idc_schema_check.py <issue-body.md>\n")
        sys.exit(2)
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            text = fh.read()
    except OSError as e:
        sys.stderr.write(f"idc-schema-check: cannot read {sys.argv[1]}: {e}\n")
        sys.exit(2)
    problems = check(text)
    if problems:
        print("schema check: FAIL")
        for p in problems:
            print(f"  - {p}")
        sys.exit(1)
    print("schema check: PASS")
    sys.exit(0)


if __name__ == "__main__":
    main()
