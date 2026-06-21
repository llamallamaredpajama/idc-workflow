#!/usr/bin/env python3
"""idc_acceptance_check.py — the dependency-aware wave-close acceptance gate (`WORKFLOW.md §4.3`).

The deterministic completeness check the Build wave-close (and the finisher's ship decision) runs
so a merged-"Done" issue can never ship INERT (autorun audit Fix B). It reads the tracker state
block — the same fenced-JSON the autorun drain predicate reads — and asserts that no Done issue
carries an UNMET acceptance obligation.

The obligation is a structured **deferral** the closeout serializes onto the issue as a comment
marker (no dedicated tracker field, no seventh op — `comment` is one of the six core ops, and both
backends carry comments; `WORKFLOW.md §3.3` holds):

    <!-- idc-deferral: {"kind": "...", "what": "...", "blocks_goal": true, "suggested_issue": "#365"} -->

A deferral is "met" when `blocks_goal` is false, OR its `suggested_issue` names a **distinct**
tracker issue (`#<number>`) that is itself `Done` **and not itself inert** (transitive — an enabler
that is Done-but-inert does not satisfy the obligation). A `blocks_goal: true` deferral that
resolves to no clean Done enabler — free text, a non-Done sibling, a self-reference, or a Done-but-
inert enabler — is an ACCEPTANCE GAP: the increment is Done on the board but inert in reality (e.g.
a DDL merged with no provisioned instance, #449). On a gap, the wave-close step auto-files a
recirculation instead of reporting green. Inertness is evaluated over the **whole board**,
independent of `--wave`, so an out-of-wave enabler is never assumed clean.

Optional `--wave N` scopes which Done issues are *reported* to one wave (matched by the issue's
`wave` field); it does not narrow the enabler-inertness evaluation. A `--wave` value carrying no
wave number is a usage error (exit 2), never a silent whole-board fallback.

Prints `acceptance: ok` (exit 0) or `acceptance: gap <issue#s>` (exit 1); exit 2 on a malformed
tracker, corrupt issue, an unparseable deferral marker, a `blocks_goal` that is not a real JSON
boolean (null/missing/string/number all fail closed), or a `--wave` with no number.

Usage: idc_acceptance_check.py --tracker <TRACKER.md> [--wave N]   (exit 0 = ok, 1 = gap, 2 = error)
"""
import argparse
import json
import re
import sys

BEGIN = "<!-- idc-tracker-state:begin -->"
END = "<!-- idc-tracker-state:end -->"
# A closeout serializes each unresolved obligation as this hidden marker in an issue comment. The
# sentinel is matched FIRST (the payload is captured up to the comment close), so a corrupt payload
# fails closed rather than slipping past a `{…}`-anchored pattern as "no deferral".
DEFERRAL_MARKER = re.compile(r"<!--\s*idc-deferral:\s*(.*?)\s*-->", re.S)


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(re.escape(BEGIN) + r"\s*```json\s*(.*?)\s*```\s*" + re.escape(END), text, re.S)
    if not m:
        sys.stderr.write(f"idc-acceptance-check: no tracker state block in {path}\n")
        sys.exit(2)
    state = json.loads(m.group(1))
    if not isinstance(state, dict):
        sys.stderr.write(f"idc-acceptance-check: tracker state block is not a JSON object in {path}\n")
        sys.exit(2)
    return state


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


def deferrals_of(issue):
    """Parse the structured deferral markers a closeout posted to an issue's comments.

    The deferral object is validated at review time by idc_review_verdict_check.py; here the gate
    only needs to re-read it from where the finisher landed it. A marker whose payload is unparseable
    JSON — or is valid JSON that is not an object — is corruption, not "no deferral": fail closed
    (exit 2), never silently skip a possible gap."""
    out = []
    comments = issue.get("comments", [])
    # A string `comments` (a hand-edited tracker, or a sloppy github materialization) would make the
    # loop iterate CHARACTERS, so an embedded marker is never matched and an inert Done could pass as
    # `acceptance: ok`. Fail closed on any non-list shape rather than silently scan nothing.
    if not isinstance(comments, list):
        sys.stderr.write(f"idc-acceptance-check: issue {issue.get('number')} `comments` must be a "
                         f"list (got {type(comments).__name__})\n")
        sys.exit(2)
    for c in comments:
        for mk in DEFERRAL_MARKER.finditer(str(c)):
            try:
                obj = json.loads(mk.group(1))
            except json.JSONDecodeError as e:
                sys.stderr.write(f"idc-acceptance-check: issue {issue.get('number')} has an "
                                 f"unparseable idc-deferral marker ({e})\n")
                sys.exit(2)
            if not isinstance(obj, dict):
                sys.stderr.write(f"idc-acceptance-check: issue {issue.get('number')} idc-deferral "
                                 f"marker is not a JSON object (got {type(obj).__name__})\n")
                sys.exit(2)
            out.append(obj)
    return out


def _has_unmet(num, status_by_num, done_deferrals, memo, stack):
    """True if Done issue `num` carries a `blocks_goal:true` deferral that is NOT met.

    "met" = the deferral names a DISTINCT issue (`#<n>`) that is itself `Done` AND not itself inert
    (transitive). Memoized and cycle-safe: an issue currently on the resolution stack (a reference
    cycle) resolves to inert — it cannot be cleanly enabled, so fail closed."""
    if num in memo:
        return memo[num]
    if num in stack:
        return True
    stack.add(num)
    unmet = False
    for d in done_deferrals.get(num, []):
        if d.get("blocks_goal") is not True:        # blocks_goal validated as bool in gaps()
            continue
        ref = issue_ref(d.get("suggested_issue", ""))
        met = (ref is not None and ref != num and status_by_num.get(ref) == "Done"
               and not _has_unmet(ref, status_by_num, done_deferrals, memo, stack))
        if not met:
            unmet = True
            break
    stack.discard(num)
    memo[num] = unmet
    return unmet


def gaps(state, wave=None):
    """Sorted issue numbers that are Done-but-inert (an unmet blocks_goal:true deferral, transitively),
    filtered to `--wave N` when given."""
    issues = state.get("issues", [])
    if not isinstance(issues, list):
        sys.stderr.write("idc-acceptance-check: corrupt tracker — `issues` must be a list\n")
        sys.exit(2)
    for it in issues:
        if not isinstance(it, dict):
            sys.stderr.write("idc-acceptance-check: corrupt tracker — an issue is not a JSON object\n")
            sys.exit(2)
        if "number" not in it:
            sys.stderr.write("idc-acceptance-check: corrupt tracker — an issue is missing `number`\n")
            sys.exit(2)
    if wave is not None and wave_num(wave) is None:
        sys.stderr.write(f"idc-acceptance-check: --wave {wave!r} carries no wave number\n")
        sys.exit(2)
    status_by_num = {it["number"]: it.get("status") for it in issues}
    # Parse + validate every Done issue's deferrals ONCE, whole-board — so transitivity and the
    # fail-closed marker/blocks_goal checks are wave-independent: an out-of-wave enabler is never
    # assumed clean, and a bad marker or non-boolean blocks_goal anywhere is caught.
    done_deferrals = {}
    for it in issues:
        if it.get("status") != "Done":
            continue
        ds = deferrals_of(it)                        # exits 2 on an unparseable marker
        for d in ds:
            bg = d.get("blocks_goal")
            # The validator (idc_review_verdict_check.py) requires a real JSON boolean upstream; the
            # gate is the last-resort defense, so anything else — null, a missing key, the string
            # "true", a number — fails closed (exit 2) rather than being mis-read as non-blocking.
            if not isinstance(bg, bool):
                sys.stderr.write(f"idc-acceptance-check: issue {it['number']} deferral `blocks_goal` "
                                 f"must be a JSON boolean (got {type(bg).__name__})\n")
                sys.exit(2)
        done_deferrals[it["number"]] = ds
    want = wave_num(wave) if wave is not None else None
    memo = {}
    offending = []
    for it in issues:
        if it.get("status") != "Done":
            continue
        if want is not None and wave_num(it.get("wave")) != want:
            continue
        if _has_unmet(it["number"], status_by_num, done_deferrals, memo, set()):
            offending.append(it["number"])
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
