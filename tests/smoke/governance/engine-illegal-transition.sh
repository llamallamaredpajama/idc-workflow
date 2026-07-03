#!/bin/bash
# engine-illegal-transition.sh — governance scenario: the transition engine refuses transitions not
# in the machine table (templates/workflow-machine.yaml).
#
# The invariant (v4 Phase 2, plan §3.1): idc_transition.py is the ONE write door, and it enforces the
# legal-transition table declared as data. A transition the machine forbids ⇒ error (exit 2), NOT a
# silent illegal write. Proven on the filesystem backend.
#
# Three forbidden transitions, each red-when-broken:
#   (1) claim a Recirculation item — the recirc inbox is drained by /idc:recirculate, never claimed
#       as build work (machine: claim.forbidden_stages includes Recirculation).
#   (2) claim a Consideration pointer — decomposed by Plan, never claimed (forbidden_stages).
#   (3) move an item to Done — a terminal Done must go through `close`/`retire` so its guards run
#       (machine: move.forbidden_to includes Done).
# Break the corresponding check in idc_transition.py::run → the forbidden op SUCCEEDS → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-illegal-transition.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
fail() { echo "FAIL: $1"; exit 1; }
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$ENGINE" ] || fail "transition engine not found at $ENGINE (not implemented yet)"

T="$(gov_new_tracker)" || fail "gov_new_tracker could not init a throwaway TRACKER.md"
REPO="$(dirname "$T")"
trap 'rm -rf "$REPO"' EXIT
eng() { python3 "$ENGINE" --repo "$REPO" --backend filesystem --tracker "$T" "$@"; }

# Seed one item per forbidden stage + a buildable one to move.
recirc="$(gov_seed_item "$T" --title 'inbox nit' --stage Recirculation --status Todo)" || fail "seed recirc failed"
consid="$(gov_seed_item "$T" --title 'pointer'   --stage Consideration --status Todo)" || fail "seed consideration failed"
build="$( gov_seed_item "$T" --title 'build'     --stage Buildable     --status Todo)" || fail "seed buildable failed"

# (1) claim a Recirculation item ⇒ denied.
if eng claim --num "$recirc" 2>/dev/null; then
  fail "(1) engine allowed claim on a Recirculation item (should be forbidden)"
fi
[ "$(gov_field "$T" "$recirc" Status)" = "Todo" ] || fail "(1) denied claim still mutated the item's Status"
echo "  ok (1) claim on a Recirculation item is refused (illegal transition)"

# (2) claim a Consideration pointer ⇒ denied.
if eng claim --num "$consid" 2>/dev/null; then
  fail "(2) engine allowed claim on a Consideration pointer (should be forbidden)"
fi
echo "  ok (2) claim on a Consideration pointer is refused (illegal transition)"

# (3) move a Buildable item to Done ⇒ denied (terminal Done must go through close/retire).
if eng move --num "$build" --to-status Done 2>/dev/null; then
  fail "(3) engine allowed move-to-Done (Done must go through close/retire so guards run)"
fi
[ "$(gov_field "$T" "$build" Status)" = "Todo" ] || fail "(3) denied move-to-Done still mutated Status"
echo "  ok (3) move-to-Done is refused (terminal Done is guarded via close/retire)"

# Sanity: a LEGAL transition (claim a Buildable) still succeeds — the engine is not just denying all.
eng claim --num "$build" >/dev/null 2>&1 || fail "(sanity) engine denied a LEGAL claim on a Buildable item"
[ "$(gov_field "$T" "$build" Status)" = "In Progress" ] || fail "(sanity) legal claim did not set In Progress"
echo "  ok (sanity) a legal claim on a Buildable item still succeeds"

echo "PASS: transition engine refuses illegal transitions (claim on Recirculation/Consideration; move-to-Done) while allowing legal ones"
