#!/bin/bash
# dispose-gate-approved.sh — governance scenario: the `gate-approved` terminal disposition (#150).
#
# An approved operator gate (a requirements Think gate or a strategic operator-decision gate) is a
# NON-verdict terminal disposition: it carries no review verdict, so the verdict-guarded `close`
# cannot close it, and before #150 the operator closed it through a RAW tracker close that bypassed
# the engine + journal. The new guarded op `dispose --disposition gate-approved` mints Done ONLY when
# the `gate-approval-artifact` guard passes.
#
# On the FILESYSTEM backend a repo has no PRs and no labels, so the durable approval artifact is the
# operator's own explicit Done-move (the PR #73 gate-item semantics) — the guard confines the op to a
# genuine `[operator-action]` gate item (by title prefix) so it can NEVER be used to mint a
# verdict-free Done for ordinary build work. (The github backend additionally verifies a merged
# Think/decision PR or the decision-approved label — see dispose-gate-approved-github.sh.)
#
# Red-when-broken (the mutation proof): neuter check_gate_approved (return without raising) → a
# NON-gate item closes to Done → this FAILs.
#
# Usage: bash tests/smoke/governance/dispose-gate-approved.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# ── 1. HAPPY PATH: an [operator-action] gate item closes to Done via the gate-approved disposition ──
g="$(gov_seed_item "$T" --title '[operator-action] Requirements change — the app greets by name' --stage Buildable --status Todo)" \
  || fail "could not seed the operator-action gate item"
eng dispose --disposition gate-approved --num "$g" >/dev/null 2>&1 \
  || fail "dispose --disposition gate-approved refused a genuine [operator-action] gate item"
[ "$(gov_field "$T" "$g" Status)" = "Done" ] || fail "gate-approved disposition did not drive the gate to Done"
echo "  ok (1) an [operator-action] gate item closes to Done via dispose --disposition gate-approved"

# ── 2. DENY: an ordinary (non-gate) work item is refused — gate-approved is not a verdict-free door ─
w="$(gov_seed_item "$T" --title 'implement the greeting banner' --stage Buildable --status 'In Progress')" \
  || fail "could not seed the ordinary work item"
if eng dispose --disposition gate-approved --num "$w" 2>/dev/null; then
  fail "gate-approved closed an ordinary work item (a verdict-free backdoor to Done — guard bypassed)"
fi
[ "$(gov_field "$T" "$w" Status)" != "Done" ] || fail "denied gate-approved still drove the work item to Done"
echo "  ok (2) an ordinary (non-[operator-action]) work item is REFUSED (no verdict-free Done for build work)"

echo "PASS: dispose --disposition gate-approved mints Done ONLY for a genuine [operator-action] gate item on the filesystem backend (the operator's explicit Done-move, PR #73 semantics); an ordinary work item is fail-closed"
