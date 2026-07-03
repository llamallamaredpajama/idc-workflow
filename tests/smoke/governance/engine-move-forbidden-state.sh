#!/bin/bash
# engine-move-forbidden-state.sh — governance scenario: there is NO second path around claim's
# forbidden-stage rule. `move` (and any transition op) cannot drive an item to the worked Status
# (In Progress) on a non-build Stage that `claim` forbids.
#
# The gap this closes (PR #133 review MAJOR-1): `eng move --to-status "In Progress"` reached the same
# worked state on Recirculation/Consideration items that `claim` refuses. The engine now enforces the
# worked-state invariant (worked_status × worked_forbidden_stages in workflow-machine.yaml) for EVERY
# transition op, so the door has one gate, not a per-op patch.
#
# Red-when-broken: neuter idc_transition.check_worked_state → the forbidden `move` SUCCEEDS → FAILs.
#
# Usage: bash tests/smoke/governance/engine-move-forbidden-state.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

recirc="$(gov_seed_item "$T" --title 'inbox' --stage Recirculation --status Todo)" || fail "seed recirc failed"
consid="$(gov_seed_item "$T" --title 'ptr'   --stage Consideration --status Todo)" || fail "seed consideration failed"
build="$( gov_seed_item "$T" --title 'build' --stage Buildable     --status Todo)" || fail "seed buildable failed"

# (1) move a Recirculation item to In Progress ⇒ denied (same state claim forbids).
if eng move --num "$recirc" --to-status "In Progress" 2>/dev/null; then
  fail "(1) move drove a Recirculation item to In Progress (a second path around claim.forbidden)"
fi
[ "$(gov_field "$T" "$recirc" Status)" = "Todo" ] || fail "(1) denied move still mutated Status"
echo "  ok (1) move-to-In-Progress on a Recirculation item is refused"

# (2) move a Consideration pointer to In Progress ⇒ denied.
if eng move --num "$consid" --to-status "In Progress" 2>/dev/null; then
  fail "(2) move drove a Consideration pointer to In Progress"
fi
echo "  ok (2) move-to-In-Progress on a Consideration pointer is refused"

# (3) a NON-worked move on a non-build Stage is still fine (Recirculation → Blocked).
eng move --num "$recirc" --to-status Blocked >/dev/null 2>&1 \
  || fail "(3) engine wrongly denied a non-worked move (Recirculation → Blocked)"
[ "$(gov_field "$T" "$recirc" Status)" = "Blocked" ] || fail "(3) non-worked move did not land"
echo "  ok (3) a non-worked move on a non-build Stage still succeeds"

# (4) move-to-In-Progress on a Buildable item is legal (the invariant is stage-specific, not blanket).
eng move --num "$build" --to-status "In Progress" >/dev/null 2>&1 \
  || fail "(4) engine wrongly denied move-to-In-Progress on a Buildable item"
[ "$(gov_field "$T" "$build" Status)" = "In Progress" ] || fail "(4) legal worked move did not land"
echo "  ok (4) move-to-In-Progress on a Buildable item still succeeds"

echo "PASS: the worked-state invariant closes every path — move/claim cannot reach In Progress on a non-build Stage, while build-stage and non-worked transitions still succeed"
