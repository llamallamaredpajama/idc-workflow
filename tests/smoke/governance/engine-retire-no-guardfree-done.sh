#!/bin/bash
# engine-retire-no-guardfree-done.sh — governance scenario: NO verdict-free path to Done exists.
#
# The gap this closes (PR #133 review, upgraded MAJOR): `retire` drove ANY item to Done with no
# guard. Under THE terminal invariant — the only path to a terminal Status is a guarded `close`
# whose verdict is valid, passing, and owns the item — a guard-free terminal op cannot reach Done.
# The board has a single terminal Status (Done), so `retire` (no verdict) is FAIL-CLOSED this stage
# (a distinct non-Done "closed-not-planned" disposition is a Phase-4 board-schema change).
#
# Red-when-broken: give `retire` a to_status of Done via a non-empty/relaxed guard path (or remove
# the "guard-free terminal op is refused" check in idc_transition.run) → retire reaches Done → FAILs.
#
# Usage: bash tests/smoke/governance/engine-retire-no-guardfree-done.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

# retire is refused on EVERY stage — build or non-build — because none is a guarded, verdict-backed
# path to Done. (A build item goes through `close`; a non-build item awaits the Phase-4 disposition.)
for spec in "Buildable:In Progress" "Consideration:Todo" "Recirculation:Todo" "Planning:Todo"; do
  stage="${spec%%:*}"; status="${spec#*:}"
  n="$(gov_seed_item "$T" --title "x on $stage" --stage "$stage" --status "$status")" || fail "seed on $stage failed"
  if eng retire --num "$n" 2>/dev/null; then
    fail "retire reached a terminal Done on a Stage=$stage item (verdict-free path to Done)"
  fi
  [ "$(gov_field "$T" "$n" Status)" != "Done" ] || fail "denied retire still drove the Stage=$stage item to Done"
  echo "  ok retire is refused on a Stage=$stage item (no verdict-free Done)"
done

# And a guarded `close` DOES reach Done (proving Done is reachable — just only through the one door).
n="$(gov_seed_item "$T" --title 'proper build' --stage Buildable --status 'In Progress')" || fail "seed failed"
cat > "$REPO/v.json" <<JSON
{"verdict":"PASS","pr":9,"issue":$n,"findings":[]}
JSON
eng close --num "$n" --verdict "$REPO/v.json" --pr 9 >/dev/null 2>&1 || fail "the guarded close path to Done is broken"
[ "$(gov_field "$T" "$n" Status)" = "Done" ] || fail "guarded close did not reach Done"
echo "  ok the guarded close (valid, passing, item-owning verdict) DOES reach Done — the sole path"

echo "PASS: no verdict-free path to Done — retire is fail-closed on every stage; only a guarded close reaches Done"
