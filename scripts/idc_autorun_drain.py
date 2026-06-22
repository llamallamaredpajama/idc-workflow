#!/usr/bin/env python3
"""idc_autorun_drain.py — Autorun's drain predicate (`WORKFLOW.md §4.5`).

Autorun is the one-shot full-pipe drainer: it keeps claiming build work while any is
actionable and exits when nothing actionable remains (only Done items, requirements-gated
Blocked items, the operator's own gate issues, and un-admitted considerations left). This helper
computes the build lane's eligibility over the filesystem tracker — the deterministic exit
condition.

Eligible build work = an issue that is:
  * `Status = Todo`,
  * `Stage = Buildable` (or no Stage on a legacy 4-field repo) — an upstream pointer item
    (`Stage = Consideration`/`Planning`) is never scooped as build work (the glass wall). A
    `Stage = Consideration` pointer is a consideration **pending admission behind its Think PR**
    (the one gate), so it must never be built past until the operator merges that PR,
  * NOT an operator-action gate issue (title starting with `[operator-action]`), and
  * has every native blocked-by upstream `Done`.

Prints the eligible issue numbers and `drain: continue` (work remains) or `drain: complete`
(exit). The planning lane (unplanned considerations) is scanned by the orchestrator from the
filesystem; this helper covers the build lane / board-exit half.

With `--width`, one extra line reports the ready frontier's width:
  width: <N>     (the cardinality of the `eligible:` set already printed above)
Width is the max-useful parallelism the CURRENT ready frontier can staff — the size of the unblocked
eligible antichain (Wave is never consulted, so different waves do not partition it; a blocked
dependent and a glass-wall Consideration/Planning pointer are excluded by the same eligibility
predicate). Autorun's parent reads it as the sous-chef count feeding the launch-time staffing
estimate — one `--width` call reports the frontier right now; the cross-`/loop` estimate sums these
across iterations, not a single invocation. The flag is opt-in so the default output stays
byte-identical for existing callers (the ready set is always on the `eligible:` line, with or without it).

Usage: idc_autorun_drain.py --tracker <TRACKER.md> [--width]   (exit 0 = ok, 2 = error)
"""
import argparse
import json
import re
import sys

BEGIN = "<!-- idc-tracker-state:begin -->"
END = "<!-- idc-tracker-state:end -->"


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(re.escape(BEGIN) + r"\s*```json\s*(.*?)\s*```\s*" + re.escape(END), text, re.S)
    if not m:
        sys.stderr.write(f"idc-autorun-drain: no tracker state block in {path}\n")
        sys.exit(2)
    state = json.loads(m.group(1))
    if not isinstance(state, dict):
        sys.stderr.write(f"idc-autorun-drain: tracker state block is not a JSON object in {path}\n")
        sys.exit(2)
    return state


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tracker", required=True)
    ap.add_argument("--width", action="store_true",
                    help="also print the ready frontier's width (max-useful parallelism); the ready set is the `eligible:` line")
    args = ap.parse_args()
    try:
        state = load(args.tracker)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"idc-autorun-drain: cannot read {args.tracker}: {e}\n")
        sys.exit(2)

    # A MISSING `issues` key is corruption (e.g. a github bug that drops it), not an empty board:
    # fail closed rather than read it as zero issues and print `drain: complete`. An explicit
    # `issues: []` is still a legitimate empty board. (The sibling idc_acceptance_check.py applies the
    # identical guard, kept in lockstep by the smoke parity tests.)
    if "issues" not in state:
        sys.stderr.write("idc-autorun-drain: corrupt tracker — state block has no `issues` key\n")
        sys.exit(2)
    issues = state["issues"]
    if not isinstance(issues, list):
        sys.stderr.write("idc-autorun-drain: corrupt tracker — `issues` must be a list\n")
        sys.exit(2)
    # eager guard: every entry must be a dict (membership tests, `.get()`, the sort key, and
    # `.startswith()` below all assume it), the dict-comp and sort key subscript it["number"]
    # unconditionally, and the eligibility loop ITERATES it["blocked_by"] — so a corrupt issue must
    # fail loudly here rather than KeyError/TypeError mid-computation. A scalar entry (e.g.
    # `issues: [5]`) or a non-list blocked_by (a github bug or a hand-edit dropping the brackets)
    # would otherwise crash the loop (exit 1, traceback) or be silently misread; fail closed
    # (exit 2) instead, like the sibling idc_acceptance_check.py guards its own dereferenced fields.
    for it in issues:
        if not isinstance(it, dict):
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue is not an object\n")
            sys.exit(2)
        if "number" not in it:
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue is missing `number`\n")
            sys.exit(2)
        if not isinstance(it["number"], int):
            # `number` is a dict key (status_by_num) AND a sort key — an unhashable/unsortable value
            # crashes instead of exiting 2. The filesystem tracker always writes an int.
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue `number` must be an int\n")
            sys.exit(2)
        if not isinstance(it.get("blocked_by", []), list):
            sys.stderr.write(
                f"idc-autorun-drain: corrupt tracker — issue {it['number']} `blocked_by` must be a list\n")
            sys.exit(2)
    status_by_num = {it["number"]: it.get("status") for it in issues}
    eligible = []
    for it in sorted(issues, key=lambda x: x["number"]):
        if it.get("status") != "Todo":
            continue
        if it.get("stage") in ("Consideration", "Planning"):
            continue  # an upstream pointer item, not build work (the glass wall)
        if str(it.get("title", "")).strip().startswith("[operator-action]"):
            continue  # the operator's gate issue, not build work
        if all(status_by_num.get(b) == "Done" for b in it.get("blocked_by", [])):
            eligible.append(it["number"])

    print("eligible: " + " ".join(str(n) for n in eligible))
    print("drain: " + ("continue" if eligible else "complete"))
    if args.width:
        # The ready frontier IS the `eligible:` set already printed above; width is its size = the
        # unblocked eligible antichain that can be staffed in parallel right now (the sous-chef
        # count; Wave is never consulted). No `ready-frontier:` line — it would byte-duplicate
        # `eligible:`; consumers read the ready set from `eligible:` and the count from here.
        print("width: " + str(len(eligible)))


if __name__ == "__main__":
    main()
