#!/bin/bash
# engine-terminal-not-resurrectable.sh — governance scenario: a terminal (Done) item cannot be
# resurrected by any transition op.
#
# The gap this closes (PR #133 review MINOR-3): `unblock` (and any transition op) resurrected a Done
# item back to Todo/In Progress. Done is terminal, so no transition may operate on it; `unblock`
# additionally only lifts a Blocked item (from_status: [Blocked]).
#
# Red-when-broken: remove the terminal-source check in idc_transition.run (transition branch) →
# unblock/move on a Done item SUCCEEDS → the resurrection halves FAIL.
#
# Usage: bash tests/smoke/governance/engine-terminal-not-resurrectable.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# A Done item (seed it directly at Done via the backend).
done_item="$(gov_seed_item "$T" --title 'shipped' --stage Buildable --status Done)" || fail "seed Done failed"

# (1) unblock a Done item ⇒ denied (Done is terminal; also unblock only lifts Blocked).
if eng unblock --num "$done_item" 2>/dev/null; then
  fail "(1) unblock resurrected a Done item (Done must be terminal)"
fi
[ "$(gov_field "$T" "$done_item" Status)" = "Done" ] || fail "(1) denied unblock still mutated a Done item"
echo "  ok (1) unblock cannot resurrect a Done item"

# (2) move a Done item back to In Progress ⇒ denied.
if eng move --num "$done_item" --to-status "In Progress" 2>/dev/null; then
  fail "(2) move resurrected a Done item"
fi
[ "$(gov_field "$T" "$done_item" Status)" = "Done" ] || fail "(2) denied move still mutated a Done item"
echo "  ok (2) move cannot resurrect a Done item"

# (3) unblock only lifts a Blocked item (source-Status constraint): a Blocked item unblocks to Todo.
blk="$(gov_seed_item "$T" --title 'blocked' --stage Buildable --status Blocked)" || fail "seed Blocked failed"
eng unblock --num "$blk" >/dev/null 2>&1 || fail "(3) unblock denied a genuinely Blocked item"
[ "$(gov_field "$T" "$blk" Status)" = "Todo" ] || fail "(3) unblock did not lift Blocked → Todo"
echo "  ok (3) unblock lifts a Blocked item to Todo (source-Status constraint holds)"

echo "PASS: Done is terminal — no unblock/move resurrection; unblock only lifts a Blocked item"
