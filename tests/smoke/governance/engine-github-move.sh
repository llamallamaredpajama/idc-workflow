#!/bin/bash
# engine-github-move.sh — governance scenario: the github `move` op enforces the SAME guards as fs.
#
# Stage 1b: github move/close/link are wired through the engine (no more fail-closed stub) — and the
# terminal invariant + worked-state + resurrection rules hold IDENTICALLY on github, via the shared
# guard path (get_item/refuse_terminal/check_worked_state), not a parallel codepath.
#
# github is not hermetically testable, so this UNIT-tests in-process: idc_gh_board.fetch_item/set_status
# and the item-id cache are monkeypatched; the assertions are on whether the real gh mutation
# (set_status) is/ isn't called. Red-when-broken: neuter the corresponding guard in idc_transition →
# a DENIED move performs the write → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-github-move.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env   # for a throwaway $REPO (keeps the journal stub out of the plugin tree)

python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github move unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

CUR = {"stage": "Buildable", "status": "Todo"}
sets = []
B.fetch_item = lambda iid, r: dict(CUR)
def set_status(o, p, r, iid, s): sets.append(s); CUR["status"] = s
B.set_status = set_status
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

def is_denied(fn):
    try: fn(); return False
    except E.TransitionError: return True

# (1) legal move Buildable/Todo -> In Progress: the gh set_status IS called and reads back.
CUR.update(stage="Buildable", status="Todo"); sets.clear()
E.run("move", ctx, num=5, to_status="In Progress")
assert sets == ["In Progress"], f"legal github move did not call set_status once: {sets}"
print("  ok (1) legal github move performs the gh Status write (set_status)")

# (2) move -> Done DENIED (refuse_terminal): only a guarded close reaches Done; set_status NOT called.
CUR.update(stage="Buildable", status="Todo"); sets.clear()
assert is_denied(lambda: E.run("move", ctx, num=5, to_status="Done")), "github move-to-Done was allowed"
assert sets == [], f"denied move-to-Done still wrote Status: {sets}"
print("  ok (2) github move-to-Done is DENIED and performs no write")

# (3) move onto the worked Status on a non-build Stage DENIED (worked-state); no write.
CUR.update(stage="Recirculation", status="Todo"); sets.clear()
assert is_denied(lambda: E.run("move", ctx, num=5, to_status="In Progress")), "github move to In-Progress on Recirculation was allowed"
assert sets == [], f"denied worked-state move still wrote Status: {sets}"
print("  ok (3) github move onto a forbidden worked-state is DENIED and performs no write")

# (4) move a terminal (Done) item DENIED (resurrection); no write.
CUR.update(stage="Buildable", status="Done"); sets.clear()
assert is_denied(lambda: E.run("move", ctx, num=5, to_status="In Progress")), "github move resurrected a Done item"
assert sets == [], f"denied resurrection still wrote Status: {sets}"
print("  ok (4) github move cannot resurrect a Done item and performs no write")
PY

echo "PASS: github move enforces refuse_terminal + worked-state + resurrection guards identically to fs (denied moves perform no gh write)"
