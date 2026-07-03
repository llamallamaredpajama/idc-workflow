#!/bin/bash
# engine-readback-verify.sh — governance scenario: every engine op READS BACK the item after the
# write and refuses success on a divergence (a write that did not land is never reported as success).
#
# The invariant (v4 Phase 2, plan §3.1): extends idc_gh_close.py's read-back posture to every op —
# after mutating, the engine reads the item's observed (Stage, Status) and raises TransitionError
# unless it matches the intended target.
#
# Two halves, both red-when-broken:
#   (A) UNIT — idc_transition.verify_readback raises on a Status/Stage divergence and passes on a
#       match. Neuter verify_readback → (A) FAILs.
#   (B) SEAM — with fs_get_item (the single read-back seam) monkeypatched to LIE (report a stale
#       Status), a real `move` through the engine must still raise (the read-back catches the
#       injected divergence). Remove the verify_readback call from the op path → the lie is ignored
#       → (B) FAILs. A clean (un-monkeypatched) move still succeeds (the engine is not raising
#       spuriously).
#
# Usage: bash tests/smoke/governance/engine-readback-verify.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE (not implemented yet)"

T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
n="$(gov_seed_item "$T" --title 'build' --stage Buildable --status Todo)" || fail "seed failed"

python3 - "$GOV_PLUGIN/scripts" "$REPO" "$T" "$n" <<'PY' || fail "read-back assertions failed (see above)"
import sys
scripts, repo, tracker, num = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
sys.path.insert(0, scripts)
import idc_transition as E

# ── (A) UNIT: verify_readback raises on divergence, passes on a match. ──
try:
    E.verify_readback(num, None, "In Progress", "Buildable", "Todo")  # Status diverges
    print("FAIL: verify_readback accepted a Status divergence"); sys.exit(1)
except E.TransitionError:
    pass
try:
    E.verify_readback(num, "Buildable", "Todo", "Recirculation", "Todo")  # Stage diverges
    print("FAIL: verify_readback accepted a Stage divergence"); sys.exit(1)
except E.TransitionError:
    pass
E.verify_readback(num, "Buildable", "Todo", "Buildable", "Todo")  # exact match → no raise
print("  ok (A) verify_readback raises on a Stage/Status divergence, passes on a match")

ctx = E.fs_ctx(repo, tracker)

# ── (B) SEAM: monkeypatch fs_get_item to LIE about the post-write Status → the op must raise. ──
orig = E.fs_get_item
def lying_get_item(t, nnum):
    real = orig(t, nnum)
    real["status"] = "Todo"   # pretend the write never landed (stale value)
    return real
E.fs_get_item = lying_get_item
try:
    E.run("move", ctx, num=num, to_status="In Progress")
    print("FAIL: op succeeded despite a read-back divergence (write-not-landed reported as success)"); sys.exit(1)
except E.TransitionError:
    pass
finally:
    E.fs_get_item = orig
print("  ok (B) a monkeypatched read-back divergence makes the op raise (write-not-landed is caught)")

# ── clean op still succeeds (no spurious read-back failure). ──
E.run("move", ctx, num=num, to_status="In Progress")
if orig(tracker, num)["status"] != "In Progress":
    print("FAIL: a clean move did not actually land"); sys.exit(1)
print("  ok (clean) an un-monkeypatched move succeeds and lands")
PY

echo "PASS: every engine op reads back the written item and refuses success on a divergence (a write that did not land is never a success)"
