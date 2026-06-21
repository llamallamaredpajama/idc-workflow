#!/usr/bin/env python3
"""idc_acceptance_check.py — the dependency-aware wave-close acceptance gate (`WORKFLOW.md §4.3`).

The deterministic completeness check the Build wave-close (and the finisher's ship decision) runs
so a merged-"Done" issue can never ship INERT (autorun audit Fix B). It reads the tracker state
block — the same fenced-JSON the autorun drain predicate reads — and asserts that no Done issue
carries an UNMET acceptance obligation.

The obligation signal is the structured deferral `{kind, what, blocks_goal, suggested_issue}`
(validated at review time by `idc_review_verdict_check.py`). A deferral is "met" when
`blocks_goal` is false, OR its `suggested_issue` names a tracker issue (`#<number>`) that is
itself `Done`. A `blocks_goal: true` deferral that resolves to no Done enabler — free text, or a
sibling that isn't Done — is an ACCEPTANCE GAP: the increment is Done on the board but inert in
reality (e.g. a DDL merged with no provisioned instance, #449). On a gap, the wave-close step
auto-files a recirculation instead of reporting green.

Optional `--wave N` scopes the check to one wave (matched by the issue's `wave` field).

Prints `acceptance: ok` (exit 0) or `acceptance: gap <issue#s>` (exit 1); exit 2 on a malformed
tracker or corrupt issue/deferral.

Usage: idc_acceptance_check.py --tracker <TRACKER.md> [--wave N]   (exit 0 = ok, 1 = gap, 2 = error)
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
        sys.stderr.write(f"idc-acceptance-check: no tracker state block in {path}\n")
        sys.exit(2)
    return json.loads(m.group(1))


def wave_num(value):
    """First integer in a wave value ('Wave 4' -> 4, 4 -> 4), or None."""
    m = re.search(r"\d+", str(value))
    return int(m.group()) if m else None


def issue_ref(value):
    """The issue number an explicit `#<n>` ref names ('#365 …' -> 365), or None.

    Requires the `#` so a routed obligation is an explicit board ref — an incidental number in
    free text never counts as resolved (fail-closed)."""
    m = re.search(r"#(\d+)", str(value))
    return int(m.group(1)) if m else None


def gaps(state, wave=None):
    """Sorted issue numbers that are Done-but-inert (an unmet blocks_goal:true deferral)."""
    issues = state.get("issues", [])
    for it in issues:
        if "number" not in it:
            sys.stderr.write("idc-acceptance-check: corrupt tracker — an issue is missing `number`\n")
            sys.exit(2)
    status_by_num = {it["number"]: it.get("status") for it in issues}
    want = wave_num(wave) if wave is not None else None
    offending = []
    for it in issues:
        if it.get("status") != "Done":
            continue
        if want is not None and wave_num(it.get("wave")) != want:
            continue
        deferrals = it.get("deferrals", [])
        if not isinstance(deferrals, list):
            sys.stderr.write(f"idc-acceptance-check: issue {it['number']} `deferrals` must be a list\n")
            sys.exit(2)
        for d in deferrals:
            if not isinstance(d, dict):
                sys.stderr.write(f"idc-acceptance-check: issue {it['number']} has a non-object deferral\n")
                sys.exit(2)
            # only a real boolean True blocks the GOAL; the verdict checker rejects a non-bool
            # blocks_goal upstream, so anything else here is a non-blocking note.
            if d.get("blocks_goal") is not True:
                continue
            ref = issue_ref(d.get("suggested_issue", ""))
            # "met" requires a DIFFERENT issue that carries the enabling work — a deferral that
            # names its own issue is not resolved (it would let the exact inert-Done case slip).
            if ref is not None and ref != it["number"] and status_by_num.get(ref) == "Done":
                continue  # the enabling obligation is a distinct Done issue — met
            offending.append(it["number"])
            break
    return sorted(offending)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tracker", required=True)
    ap.add_argument("--wave")
    args = ap.parse_args()
    try:
        state = load(args.tracker)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"idc-acceptance-check: cannot read {args.tracker}: {e}\n")
        sys.exit(2)
    offending = gaps(state, args.wave)
    if offending:
        print("acceptance: gap " + " ".join(str(n) for n in offending))
        sys.exit(1)
    print("acceptance: ok")
    sys.exit(0)


if __name__ == "__main__":
    main()
