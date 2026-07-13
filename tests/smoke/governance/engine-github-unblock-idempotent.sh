#!/bin/bash
# engine-github-unblock-idempotent.sh — governance scenario: a github `unblock --by` rerun after a
# partial failure ("edge removed but the Status write failed") is IDEMPOTENT (Task 3, Fix 5).
#
# _gh_remove_dep must check ABSENCE FIRST: if the native blocked_by edge is already gone, it SKIPS the
# DELETE (which GitHub may 404) and proceeds to the Blocked->Todo Status move, so the rerun
# deterministically completes the remaining transition. Red-when-broken: revert to an unconditional
# DELETE-before-check → the absent-first rerun re-issues the DELETE (the 404 risk) → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-unblock-idempotent.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github unblock-idempotent unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

# The rerun state: the edge is ALREADY ABSENT (removed on the first, partially-failed run).
deletes = []
B.blocked_by_numbers = lambda child, r: []          # #7 no longer blocks #5
B.remove_blocked_by = lambda child, parent, r: deletes.append((child, parent))
B.blocked_by_comment_ids = lambda child, parent, r: []   # no marker comments left
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

# The absent-first branch of _gh_remove_dep: must NOT DELETE, must NOT raise, must return cleanly.
E._gh_remove_dep(ctx, child=5, parent=7)
assert deletes == [], f"absent-first rerun re-issued the DELETE (404 risk): {deletes}"
print("  ok github unblock rerun skips the DELETE when the edge is already absent (idempotent, no 404)")

# Sanity: when the edge IS present, the DELETE fires (the normal first-run path).
present = {5: {7}}
B.blocked_by_numbers = lambda child, r: sorted(present.get(int(child), set()))
def _remove(child, parent, r):
    deletes.append((child, parent)); present.get(int(child), set()).discard(int(parent))
B.remove_blocked_by = _remove
E._gh_remove_dep(ctx, child=5, parent=7)
assert deletes == [(5, 7)], f"present-edge path did not DELETE exactly once: {deletes}"
print("  ok github unblock DELETEs exactly once when the edge is present")

# ---- Fix 5: the DISPATCHER always removes-and-verifies the dependency FIRST, even when the pointer is
#      ALREADY Todo. The old dispatcher early-returned on Status==Todo BEFORE the removal, stranding a
#      stale blocked_by edge. Red-when-broken: revert the reorder → removal is never called → this FAILs.
present = {5: {7}}
removed = []
def _remove2(child, parent, r):
    removed.append((child, parent)); present.get(int(child), set()).discard(int(parent))
B.blocked_by_numbers = lambda child, r: sorted(present.get(int(child), set()))
B.remove_blocked_by = _remove2
B.blocked_by_comment_ids = lambda child, parent, r: []
# The pointer #5 is ALREADY Todo (Status change is a no-op) but the #7->#5 edge is STILL PRESENT.
B.fetch_item = lambda item_id, r: {"stage": "Buildable", "status": "Todo"}
def _no_status_write(*a, **k):
    raise AssertionError("set_status must NOT be called — the pointer is already Todo")
B.set_status = _no_status_write
E.run("unblock", ctx, num=5, to_status="Todo", by=7)
assert removed == [(5, 7)], f"dispatcher did NOT remove the dependency on an already-Todo pointer: {removed}"
assert 7 not in present.get(5, set()), f"the #7->#5 edge is still present after unblock: {present}"
print("  ok dispatcher unblock --by removes the stale edge even when the pointer is already Todo (Fix 5)")

# ---- round-7 Fix 3: an ILLEGAL unblock source (Status=In Progress) must refuse with NO removal ------
#      The source-Status legality check (Blocked, plus the idempotent Todo rerun) must run BEFORE the
#      dependency removal, so a refused unblock never leaves an UNJOURNALED partial mutation (the edge
#      gone but the op refused). Red-when-broken: move the from_status check back AFTER
#      remove_dependency → the removal fires before the raise → removed3 is non-empty → this FAILs.
present = {5: {7}}
removed3 = []
def _remove4(child, parent, r):
    removed3.append((child, parent)); present.get(int(child), set()).discard(int(parent))
B.blocked_by_numbers = lambda child, r: sorted(present.get(int(child), set()))
B.remove_blocked_by = _remove4
B.blocked_by_comment_ids = lambda child, parent, r: []
B.fetch_item = lambda item_id, r: {"stage": "Buildable", "status": "In Progress"}   # illegal source
try:
    E.run("unblock", ctx, num=5, to_status="Todo", by=7)
    print("FAIL: unblock from an In Progress source was NOT refused"); sys.exit(1)
except E.TransitionError:
    pass
assert removed3 == [], f"an illegal unblock REMOVED the dependency before refusing (unjournaled partial mutation): {removed3}"
assert 7 in present.get(5, set()), f"the #7->#5 edge was removed by a REFUSED unblock: {present}"
print("  ok an illegal unblock source (In Progress) refuses with NO dependency removal (Fix 3)")
PY

echo "PASS: github unblock --by is idempotent — the absent-first rerun skips the DELETE and completes, a present edge is removed exactly once"
