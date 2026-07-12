#!/bin/bash
# dispose-github-paths.sh — governance scenario: the github read paths of the `retired` + `drained`
# dispositions (the SAME guard logic as filesystem, over github's markers/board reads — Stage-1b
# precedent: one guard path, github routes it).
#
# In-process unit (github isn't hermetic): idc_gh_board._gh (issue body/comments) + fetch_item (the
# board stage/status read) + the item-id cache + idc_gh_close.close_issue are monkeypatched;
# assertions are on whether close_issue is called. Red-when-broken: neuter check_retired /
# check_drained → a mis-linked child or a Blocked ticket calls close_issue → this FAILs. Drop the
# dispatcher's pre-close FULL guard re-run (codex round-11 P1) → the child-restaged TOCTOU case
# FAILs (the piecemeal recheck only re-proved the PARENT's stage/status).
#
# Usage: bash tests/smoke/governance/dispose-github-paths.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github dispose paths unit failed (see above)"
import sys, json
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B, idc_gh_close as GC

BB = lambda child, parent: f'<!-- idc-blocked-by: {{"child":{child},"parent":{parent},"kind":"sub"}} -->'
BBLOCKS = lambda child, parent: f'<!-- idc-blocked-by: {{"child":{child},"parent":{parent},"kind":"blocks"}} -->'
SRC = '<!-- idc-recirc-source: {"origin":9,"what":"x","key":"k1"} -->'
DISC = '<!-- idc-discovery: {"what":"a swept rogue","area":"x"} -->'

# board stage/status per item id (the fetch_item read used by get_item).
STATE = {"PVTI_5": {"stage": "Planning", "status": "Todo"},        # a decomposed pointer (post-advance)
         "PVTI_6": {"stage": "Buildable", "status": "Todo"},       # its linked decomposition child
         "PVTI_7": {"stage": "Buildable", "status": "Todo"},       # a child linked to a DIFFERENT parent
         "PVTI_8": {"stage": "Recirculation", "status": "Todo"},   # a drainable recirc ticket
         "PVTI_9": {"stage": "Recirculation", "status": "Blocked"},# a gate-parked recirc ticket
         "PVTI_10": {"stage": "Recirculation", "status": "Todo"},  # a sweep-restaged rogue (marker in a COMMENT)
         "PVTI_11": {"stage": "Buildable", "status": "Todo"},      # a child linked via the native Tracked-by fallback
         "PVTI_12": {"stage": "Planning", "status": "Todo"},       # a pointer whose child mutates mid-flight
         "PVTI_13": {"stage": "Buildable", "status": "Todo"},      # that child — restaged AFTER the guard pass
         "PVTI_14": {"stage": "Buildable", "status": "Todo"}}      # a child linked to #5 by a kind=blocks edge
# issue body/comments per number (the marker source the guards parse).
ISSUE = {"6": {"body": "", "comments": [{"body": BB(6, 5)}]},      # references pointer #5
         "7": {"body": BB(7, 99), "comments": []},                 # references #99, NOT #5
         "8": {"body": SRC, "comments": []},
         "9": {"body": SRC, "comments": []},
         "10": {"body": "swept rogue", "comments": [{"body": DISC}]},   # provenance ONLY in a comment
         "11": {"body": "Tracked by:#5", "comments": []},          # native sub-issue fallback line naming #5
         "13": {"body": BB(13, 12), "comments": []},               # references pointer #12
         "14": {"body": BBLOCKS(14, 5), "comments": []}}           # names #5 but by a kind=blocks (dependency) marker

def fake_gh(args, r):
    if args[:2] == ["issue", "view"]:
        return json.dumps(ISSUE[args[2]])
    raise AssertionError(f"unexpected gh call: {args}")
B._gh = fake_gh
FETCHES = {}
def fake_fetch(iid, r):
    FETCHES[iid] = FETCHES.get(iid, 0) + 1
    if iid == "PVTI_13" and FETCHES[iid] >= 2:   # the CHILD is restaged out of Buildable mid-disposition
        return {"stage": "Planning", "status": "Todo"}
    return STATE[iid]
B.fetch_item = fake_fetch
closed = []
GC.close_issue = lambda o, p, i, r, item_id=None: closed.append(i)
ctx = E.github_ctx(repo, "o", "1", itemid_cache={n: f"PVTI_{n}" for n in (5, 6, 7, 8, 9, 10, 11, 12, 13, 14)})

def is_denied(fn):
    try: fn(); return False
    except E.TransitionError: return True

# retired (happy): pointer #5 (Planning) + Buildable child #6 whose marker names parent=5,child=6.
closed.clear()
E.run("dispose", ctx, num=5, disposition="retired", child=6)
assert closed == [5], f"github retired did not close the linked pointer: {closed}"
print("  ok github retired closes a pointer whose Buildable child's idc-blocked-by marker names it")

# retired (deny): child #7's marker names parent=99, not the pointer #5 → refused.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=5, disposition="retired", child=7)), \
    "github retired allowed a child that references a DIFFERENT parent"
assert closed == [], f"denied github retired still closed: {closed}"
print("  ok github retired refuses a child whose marker names a different parent")

# retired (deny, kind=blocks): child #14's marker names #5 correctly (parent=5, child=14) but by a
# kind=blocks (dependency) edge, not kind=sub — a blocks-edge is never a decomposition (codex
# round-13 P2). Mutation proof: drop the `m.get("kind") == "sub"` conjunct → the blocks marker
# matches parent/child → #5 retires → this FAILs.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=5, disposition="retired", child=14)), \
    "github retired allowed a child linked by a kind=blocks (dependency) marker, not a kind=sub decomposition"
assert closed == [], f"denied github retired (blocks marker) still closed: {closed}"
print("  ok github retired refuses a child whose idc-blocked-by marker is kind=blocks (a dependency, not a decomposition)")

# retired (native link): child #11 references pointer #5 via the portable adapter's `Tracked by:#5`
# sub-issue fallback (no idc-blocked-by marker) — the guard must accept that decomposition relation too.
closed.clear()
E.run("dispose", ctx, num=5, disposition="retired", child=11)
assert closed == [5], f"github retired rejected a child linked via the native Tracked-by fallback: {closed}"
print("  ok github retired accepts a child linked via the native `Tracked by:#<parent>` fallback")

# drained (happy): recirc ticket #8 (Todo) carrying the idc-recirc-source marker.
closed.clear()
E.run("dispose", ctx, num=8, disposition="drained")
assert closed == [8], f"github drained did not close the recirc ticket: {closed}"
print("  ok github drained closes a Stage=Recirculation Todo ticket carrying the recirc-source marker")

# drained (deny): recirc ticket #9 is Blocked (gate-parked) → refused.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=9, disposition="drained")), \
    "github drained allowed a Blocked (gate-parked) recirc ticket"
assert closed == [], f"denied github drained still closed: {closed}"
print("  ok github drained refuses a Blocked (gate-parked) recirc ticket")

# drained (comments): a sweep-restaged rogue whose provenance marker is only in a COMMENT drains —
# the github guard must scan body + comments (as idc_recirc_sweep does), not the body alone.
closed.clear()
E.run("dispose", ctx, num=10, disposition="drained")
assert closed == [10], f"github drained missed a rogue whose provenance is in a comment: {closed}"
print("  ok github drained scans comments (a sweep-restaged rogue with a comment-only marker drains)")

# retired TOCTOU (codex round-11 P1): the CHILD #13 is restaged out of Buildable between the guard
# pass and the close. The parent pointer #12's own stage/status never move, so the piecemeal
# parent-only recheck would close it — the pre-close FULL guard re-run must re-prove EVERY guard
# input (here: the child's Stage) and refuse.
closed.clear()
assert is_denied(lambda: E.run("dispose", ctx, num=12, disposition="retired", child=13)), \
    "github retired closed a pointer whose CHILD was restaged out of Buildable mid-disposition (guard→close race)"
assert closed == [], f"the child-restaged retire still closed: {closed}"
print("  ok github retired re-proves the CHILD's Stage at close (a mid-flight child restage is refused)")
PY

echo "PASS: github retired closes only a pointer whose Buildable child's idc-blocked-by marker names it AS kind=sub (refuses a different-parent child AND a kind=blocks dependency marker, and re-proves the child's Stage at close — a mid-flight child restage is refused); github drained closes only a non-Blocked recirc ticket with a provenance marker in body OR comments (refuses a gate-parked one)"
