#!/bin/bash
# idc-assert-class: behavior
# engine-stage-move.sh — governance scenario: the guarded Stage-transition door (round-6 Fix 6 / #151).
#
# Plan legitimately advances a Consideration pointer's Stage to Planning while its buildables are in
# flight. Before this fix there was NO sanctioned door for a Stage change: `move` only took
# --to-status, `dispose` set Status without Stage, and `set-field` refused Stage — so the ONLY way to
# advance Stage was a raw `set --field Stage`, unjournaled (the #151 gap that surfaces as replay
# divergence). This pins the fix: `move --to-stage` is the guarded Stage door on BOTH backends —
#   * it writes Stage AND Status together, validated as a machine-LEGAL pair (an illegal pair is
#     refused, exit 2), and reads BOTH back;
#   * it JOURNALS to_stage, so replay/reconciliation see the transition (no unjournaled Stage flip).
#
# Coverage (round-7 Fix 4): the guarded Stage door is exercised on BOTH backends — filesystem (via the
# `eng` CLI) AND github (in-process, low-level gh seams stubbed) — and the terminal-guard case creates a
# REAL Done pointer and proves it is refused a Stage move (no resurrection, no partial write) on each.
#
# Red-when-broken: drop the --to-stage handling in the transition branch → the Stage does not change
# (the readback/assert below FAILs) and the github legal case never calls set_single_select; drop the
# journal to_stage → the journal assert FAILs; drop the validate_target pair check → the illegal
# In-Progress-on-Consideration move stops being refused; drop the terminal-status guard in the
# --to-stage branch → the real Done pointer gets Stage-flipped on BOTH backends → the refusal FAILs.
#
# Usage: bash tests/smoke/governance/engine-stage-move.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

JOURNAL="$REPO/docs/workflow/transition-journal.ndjson"

# Seed a consideration pointer (Stage=Consideration, Status=Todo) — the shape Plan advances.
P="$(eng create-pointer --title 'pointer: decompose me' | tail -1)" \
  || fail "could not create the consideration pointer"
[ "$(gov_field "$T" "$P" Stage)" = "Consideration" ] || fail "seed pointer is not at Stage=Consideration"
[ "$(gov_field "$T" "$P" Status)" = "Todo" ] || fail "seed pointer is not at Status=Todo"

echo "== the guarded Stage door advances Consideration -> Planning (Stage AND Status land + read back) =="
eng move --num "$P" --to-stage Planning --to-status Todo || fail "guarded Stage move (Planning/Todo) was refused"
[ "$(gov_field "$T" "$P" Stage)" = "Planning" ] \
  || fail "the guarded Stage move did not land Stage=Planning (got $(gov_field "$T" "$P" Stage))"
[ "$(gov_field "$T" "$P" Status)" = "Todo" ] \
  || fail "the guarded Stage move did not keep Status=Todo (got $(gov_field "$T" "$P" Status))"
echo "  ok Consideration/Todo -> Planning/Todo through move --to-stage"

echo "== the Stage transition is JOURNALED with to_stage (replay/reconciliation see it) =="
[ -f "$JOURNAL" ] || fail "no transition journal was written"
python3 - "$JOURNAL" "$P" <<'PY' || fail "the guarded Stage move did not journal to_stage=Planning"
import json, sys
journal, num = sys.argv[1], int(sys.argv[2])
found = False
for line in open(journal, encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    rec = json.loads(line)
    if rec.get("op") == "move" and rec.get("item") == num \
       and (rec.get("to") or {}).get("stage") == "Planning":
        found = True
sys.exit(0 if found else 1)
PY
echo "  ok a move --to-stage record carries to.stage = Planning"

echo "== a machine-ILLEGAL Stage/Status pair is REFUSED by the guarded door (fail-closed) =="
# Consideration is a worked-forbidden Stage, so Consideration + 'In Progress' is an illegal pair.
if eng move --num "$P" --to-stage Consideration --to-status "In Progress" 2>/dev/null; then
  fail "the guarded Stage door accepted an illegal pair (Consideration + In Progress)"
fi
# The refused move left the item where it was (Planning/Todo) — no partial write.
[ "$(gov_field "$T" "$P" Stage)" = "Planning" ] \
  || fail "the refused illegal Stage move mutated Stage anyway (got $(gov_field "$T" "$P" Stage))"
echo "  ok Consideration + In Progress (a worked-forbidden pair) is refused, no partial write"

echo "== a plain --to-status move (no Stage) is unchanged (the non-Stage path is not regressed) =="
eng move --num "$P" --to-status Blocked || fail "a plain move --to-status regressed"
[ "$(gov_field "$T" "$P" Status)" = "Blocked" ] || fail "plain move --to-status did not land"
echo "  ok a plain move --to-status (no Stage) is unchanged"

echo "== a DONE pointer is REFUSED a Stage move (terminal guard, no resurrection) — real Done pointer =="
# Seed a REAL terminal (Done) pointer and prove the guarded Stage door REFUSES to Stage-move it (the
# terminal-status guard in the move --to-stage branch). Red-when-broken: drop that guard → a Done item
# gets Stage-flipped → the refusal assert below FAILs.
DONE="$(gov_seed_item "$T" --title 'pointer: done' --stage Buildable --status Done)" \
  || fail "could not seed the Done pointer"
[ "$(gov_field "$T" "$DONE" Status)" = "Done" ] || fail "seed Done pointer is not at Status=Done"
if eng move --num "$DONE" --to-stage Planning --to-status Todo 2>/dev/null; then
  fail "the guarded Stage door Stage-moved a DONE (terminal) pointer — resurrection must be refused"
fi
[ "$(gov_field "$T" "$DONE" Stage)" = "Buildable" ] \
  || fail "the refused Stage move mutated a Done pointer's Stage anyway (got $(gov_field "$T" "$DONE" Stage))"
[ "$(gov_field "$T" "$DONE" Status)" = "Done" ] \
  || fail "the refused Stage move mutated a Done pointer's Status anyway (got $(gov_field "$T" "$DONE" Status))"
echo "  ok a Done pointer is refused a Stage move, with NO partial write (Stage+Status unchanged)"

echo "== the guarded Stage door enforces the SAME rules on the GITHUB backend (not a parallel codepath) =="
# github is not hermetically testable, so this UNIT-tests in-process: the low-level gh seams are
# monkeypatched and the assertions are on whether the real gh Stage/Status writes are/aren't called.
# Red-when-broken: drop the --to-stage handling → the legal case never calls set_single_select; drop
# the terminal guard → the Done case Stage-writes anyway. Either FAILs here.
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github Stage-move unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

CUR = {"stage": "Consideration", "status": "Todo"}
stage_writes, status_writes = [], []
B.fetch_item = lambda iid, r: dict(CUR)
def _set_single_select(owner, project, r, iid, field, value):
    stage_writes.append((field, value)); CUR["stage"] = value
B.set_single_select = _set_single_select
def _set_status(o, p, r, iid, s):
    status_writes.append(s); CUR["status"] = s
B.set_status = _set_status
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

def is_denied(fn):
    try: fn(); return False
    except E.TransitionError: return True

# (1) a legal Stage move Consideration/Todo -> Planning/Todo: the gh Stage write (set_single_select) IS
#     called on the GITHUB backend (same guarded door, different seam).
CUR.update(stage="Consideration", status="Todo"); stage_writes.clear(); status_writes.clear()
E.run("move", ctx, num=5, to_stage="Planning", to_status="Todo")
assert stage_writes == [("Stage", "Planning")], f"legal github Stage move did not write Stage once: {stage_writes}"
print("  ok (github) a legal Stage move writes Stage via set_single_select")

# (2) a DONE pointer is REFUSED a Stage move on github too — the terminal guard denies BEFORE any write.
CUR.update(stage="Buildable", status="Done"); stage_writes.clear(); status_writes.clear()
assert is_denied(lambda: E.run("move", ctx, num=5, to_stage="Planning", to_status="Todo")), \
    "github guarded Stage door resurrected a Done pointer"
assert stage_writes == [] and status_writes == [], \
    f"a refused github Stage move still wrote (Stage={stage_writes}, Status={status_writes})"
print("  ok (github) a Done pointer is refused a Stage move and performs NO gh write")
PY

echo "PASS: move --to-stage is the guarded Stage-transition door on BOTH backends — it writes+reads-back a machine-legal Stage/Status pair, journals to_stage for replay, refuses an illegal pair, refuses a real Done pointer (no resurrection, no partial write), and leaves the plain --to-status move unchanged"
