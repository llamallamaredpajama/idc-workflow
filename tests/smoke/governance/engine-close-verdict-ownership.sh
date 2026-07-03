#!/bin/bash
# engine-close-verdict-ownership.sh — governance scenario: a verdict must OWN the item it closes.
#
# The gap this closes (PR #133 review BLOCKER-2): check_close_guards read verdict['issue'] ZERO
# times and --pr was optional, so ONE verdict {"pr":999,"issue":888} could close unrelated items.
# The close guard now REQUIRES: --pr mandatory, verdict['pr']==pr, AND verdict['issue']==the closing
# item. No unbound verdict may ever close anything.
#
# Red-when-broken: remove the `verdict.get("issue") != num` ownership check (or the mandatory-pr
# check) in idc_transition.check_close_guards → the cross-item close SUCCEEDS → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-close-verdict-ownership.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

a="$(gov_seed_item "$T" --title 'build A' --stage Buildable --status 'In Progress')" || fail "seed A failed"
b="$(gov_seed_item "$T" --title 'build B' --stage Buildable --status 'In Progress')" || fail "seed B failed"

# A valid PASS verdict that OWNS item A (issue==a, pr==9).
cat > "$REPO/v-for-A.json" <<JSON
{"verdict":"PASS","pr":9,"issue":$a,"findings":[]}
JSON

# A valid PASS verdict for A with NO pr field — so the mandatory-`--pr` guard is the SOLE thing
# denying case (2). (v-for-A carries pr:9, so the verdict.pr!=pr check masks the mandatory-pr guard;
# neutering it would leave case (2) green — the test would prove less than it claims. PR #134 NIT-1.)
cat > "$REPO/v-nopr.json" <<JSON
{"verdict":"PASS","issue":$a,"findings":[]}
JSON

# (1) using A's verdict to close B ⇒ denied (verdict.issue != B).
if eng close --num "$b" --verdict "$REPO/v-for-A.json" --pr 9 2>/dev/null; then
  fail "(1) a verdict for item #$a closed item #$b (unbound verdict — ownership not enforced)"
fi
[ "$(gov_field "$T" "$b" Status)" != "Done" ] || fail "(1) cross-item close still drove #$b to Done"
echo "  ok (1) a verdict for another item cannot close this one"

# (2) --pr omitted, with a verdict that ALSO has no pr field ⇒ denied by the mandatory-pr guard alone.
if eng close --num "$a" --verdict "$REPO/v-nopr.json" 2>/dev/null; then
  fail "(2) close succeeded with no --pr and no verdict.pr (unbound close)"
fi
[ "$(gov_field "$T" "$a" Status)" != "Done" ] || fail "(2) unbound close still drove #$a to Done"
echo "  ok (2) close without --pr is denied (PR binding is mandatory)"

# (3) --pr mismatched against the verdict ⇒ denied.
if eng close --num "$a" --verdict "$REPO/v-for-A.json" --pr 7 2>/dev/null; then
  fail "(3) close succeeded with --pr 7 while the verdict is for PR 9"
fi
echo "  ok (3) a --pr that disagrees with the verdict's pr is denied"

# (4) the verdict used on its OWN item + matching PR ⇒ allowed.
eng close --num "$a" --verdict "$REPO/v-for-A.json" --pr 9 >/dev/null 2>&1 \
  || fail "(4) engine denied a close where the verdict owns the item AND the PR matches"
[ "$(gov_field "$T" "$a" Status)" = "Done" ] || fail "(4) owning close did not drive #$a to Done"
echo "  ok (4) a verdict that owns the item and matches the PR closes it"

echo "PASS: close requires an item-owning, PR-bound verdict — a verdict for another item/PR (or an unbound close) is denied"
