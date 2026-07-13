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
PY

echo "PASS: github unblock --by is idempotent — the absent-first rerun skips the DELETE and completes, a present edge is removed exactly once"
