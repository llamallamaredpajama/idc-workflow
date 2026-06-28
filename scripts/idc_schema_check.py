#!/usr/bin/env python3
"""idc_schema_check.py — the mechanical issue-body schema check (`WORKFLOW.md §3.2`).

Plan runs this on every issue body before board admission. The board carries three shapes,
told apart by the `Stage:` field:

* a **buildable goal-contract** (`Stage: Buildable`, or no Stage on a legacy 4-field repo) —
  the glass-wall contract a builder works cold, so it must carry the full 6-element goal
  contract plus declared boundaries, dependencies, and trace;
* an upstream **pointer item** (`Stage: Consideration` or `Stage: Planning`) — a lightweight
  reference to a repo file (consideration / in-flight plan / pillar) carrying only a
  repo-file reference + Stage/Phase/Domain. A pointer MUST NOT duplicate canonical file
  content — it is a reference + labels, never a goal-contract; and
* a **recirculation ticket** (`Stage: Recirculation`) — the non-Buildable inbox for scope
  discovered mid-build (drained by /idc:recirculate). It carries five required scope fields
  (Discovered / Area / Suggested-scope / Provenance / PRD-TRD-impact) and, like a pointer,
  MUST NOT carry a goal-contract.

This is a lean guardrail — it checks structure and non-emptiness, not prose quality.

Buildable required labels (each on its own line): GOAL, VERIFICATION SURFACE, CONSTRAINTS,
BOUNDARIES, ITERATION POLICY, BLOCKED-STOP, ASSUMPTIONS, Dependencies, Trace. Additionally:
GOAL and VERIFICATION SURFACE must be non-empty, and BOUNDARIES must declare both `touch`
and `off-limits` (the deconfliction output).

Pointer required labels: File (repo-file reference), Phase, Domain. A pointer is REJECTED if
it carries any goal-contract marker (GOAL / VERIFICATION SURFACE) — that would duplicate
canonical content and collapse the distinction the board's Stage field draws.

Usage: idc_schema_check.py <issue-body.md>   (exit 0 = PASS, 1 = FAIL, 2 = usage)
"""
import re
import sys

CONTRACT_REQUIRED = [
    "GOAL", "VERIFICATION SURFACE", "CONSTRAINTS", "BOUNDARIES",
    "ITERATION POLICY", "BLOCKED-STOP", "ASSUMPTIONS", "Dependencies", "Trace",
]

POINTER_STAGES = ("Consideration", "Planning")
BUILDABLE_STAGE = "Buildable"
# Recirculation is pointer-class (non-Buildable, never a goal-contract) but has its OWN required
# fields, so it is NOT in POINTER_STAGES — it dispatches to check_recirculation, not check_pointer.
RECIRC_STAGE = "Recirculation"
STAGES = POINTER_STAGES + (BUILDABLE_STAGE, RECIRC_STAGE)

# The load-bearing goal-contract markers. Their presence on a pointer or a recirculation ticket
# means it is duplicating canonical content — both are references/scope notes, never a contract.
POINTER_FORBIDDEN = ("GOAL", "VERIFICATION SURFACE")

# A Recirculation ticket records scope discovered mid-build (the non-Buildable inbox drained by
# /idc:recirculate). Each field must be present AND non-empty; it carries no goal-contract.
RECIRC_REQUIRED = ("Discovered", "Area", "Suggested-scope", "Provenance", "PRD-TRD-impact")


def value_after(text, label):
    m = re.search(rf"^{re.escape(label)}:[ \t]*(.*)$", text, re.M)
    return (m.group(1).strip() if m else None)


def check(text):
    """Dispatch on Stage: pointer items and buildable goal-contracts have distinct shapes."""
    stage = value_after(text, "Stage")
    if stage and stage not in STAGES:
        return [f"unknown `Stage:` value '{stage}' (one of {', '.join(STAGES)})"]
    if stage in POINTER_STAGES:
        return check_pointer(text)
    if stage == RECIRC_STAGE:
        return check_recirculation(text)
    return check_contract(text)


def check_pointer(text):
    """A pointer carries a repo-file reference + Stage/Phase/Domain — never a goal-contract."""
    problems = []
    if not value_after(text, "File"):
        problems.append("pointer missing a repo-file reference (`File: <repo path>`)")
    for label in ("Phase", "Domain"):
        if not value_after(text, label):
            problems.append(f"pointer missing `{label}:` (a pointer carries Stage/Phase/Domain)")
    for label in POINTER_FORBIDDEN:
        if re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(
                f"pointer must not carry `{label}:` — a pointer is a reference + labels only, "
                "never a full goal-contract (that would duplicate canonical file content)")
    return problems


def check_recirculation(text):
    """A Recirculation ticket records scope discovered mid-build — never a goal-contract.

    It is pointer-class (non-Buildable, drained by /idc:recirculate) but carries its own five
    scope fields, each required AND non-empty; like a pointer it is REJECTED if it duplicates a
    goal-contract (GOAL / VERIFICATION SURFACE)."""
    problems = []
    for label in RECIRC_REQUIRED:
        if not value_after(text, label):
            problems.append(
                f"recirculation ticket missing or empty `{label}:` (a non-empty value is required)")
    for label in POINTER_FORBIDDEN:
        if re.search(rf"^{re.escape(label)}:", text, re.M):
            problems.append(
                f"recirculation ticket must not carry `{label}:` — it records discovered scope, "
                "never a full goal-contract (Plan authors the contract once the scope is admitted)")
    return problems


def check_contract(text):
    """A buildable issue is the full 6-element goal contract a builder works cold."""
    problems = []
    for label in CONTRACT_REQUIRED:
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
