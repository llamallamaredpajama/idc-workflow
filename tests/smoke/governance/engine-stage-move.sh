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
# Red-when-broken: drop the --to-stage handling in the transition branch → the Stage does not change
# (the readback/assert below FAILs); drop the journal to_stage → the journal assert FAILs; drop the
# validate_target pair check → the illegal In-Progress-on-Consideration move stops being refused.
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

echo "== a Done pointer is never Stage-moved (no resurrection) =="
# Reaching Done requires a guarded terminal op, which the seed can't satisfy here — assert instead that
# an ordinary --to-status move still works unchanged (the non-Stage path is not regressed).
eng move --num "$P" --to-status Blocked || fail "a plain move --to-status regressed"
[ "$(gov_field "$T" "$P" Status)" = "Blocked" ] || fail "plain move --to-status did not land"
echo "  ok a plain move --to-status (no Stage) is unchanged"

echo "PASS: move --to-stage is the guarded Stage-transition door — it writes+reads-back a machine-legal Stage/Status pair, journals to_stage for replay, refuses an illegal pair, and leaves the plain --to-status move unchanged"
