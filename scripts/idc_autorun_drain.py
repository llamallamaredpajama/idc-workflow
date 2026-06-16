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

Usage: idc_autorun_drain.py --tracker <TRACKER.md>   (exit 0 = ok, 2 = error)
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
    return json.loads(m.group(1))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tracker", required=True)
    args = ap.parse_args()
    try:
        state = load(args.tracker)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"idc-autorun-drain: cannot read {args.tracker}: {e}\n")
        sys.exit(2)

    issues = state.get("issues", [])
    # eager guard: the dict-comp and sort key below subscript it["number"] unconditionally,
    # so a corrupt issue must fail loudly here rather than KeyError mid-computation.
    for it in issues:
        if "number" not in it:
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue is missing `number`\n")
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


if __name__ == "__main__":
    main()
