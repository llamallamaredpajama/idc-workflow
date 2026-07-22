#!/bin/bash
# engine-close-verdict-receipt.sh — governance scenario: the engine's `close` op DENIES a close that
# lacks a validated review-verdict receipt for the item.
#
# The invariant (v4 Phase 2, plan §3.1): close is the ONLY guarded path to Done — the machine table
# declares guard `verdict-validated`, so the engine refuses to drive an item to Done unless a verdict
# JSON that passes idc_review_verdict_check.py exists at the supplied --verdict path (a guard
# evaluated against an artifact on disk, NOT a prose claim). Ownership (issue/PR binding) is proven
# separately in engine-close-verdict-ownership.sh.
#
# Red-when-broken: remove/neuter the verdict guard (idc_transition.check_close_guards → load_verdict)
# → the no-verdict close SUCCEEDS → this scenario FAILs.
#
# Usage: bash tests/smoke/governance/engine-close-verdict-receipt.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env
git -C "$REPO" init -q -b main >/dev/null 2>&1
git -C "$REPO" config user.email test@example.com >/dev/null 2>&1
git -C "$REPO" config user.name Test >/dev/null 2>&1

CHECK="$GOV_PLUGIN/scripts/idc_review_verdict_check.py"
[ -f "$CHECK" ] || fail "idc_review_verdict_check.py not found at $CHECK"
mkdir -p "$REPO/docs/workflow/code-reviews"
VERDICT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-9-review.json"

n="$(gov_seed_item "$T" --title 'build' --stage Buildable --status 'In Progress')" || fail "seed failed"

# (1) close with NO verdict receipt ⇒ denied; item stays not-Done.
if eng close --num "$n" --pr 9 2>/dev/null; then
  fail "(1) engine closed an item with NO verdict receipt (guard verdict-validated must deny)"
fi
[ "$(gov_field "$T" "$n" Status)" != "Done" ] || fail "(1) denied close still drove the item to Done"
echo "  ok (1) close with no verdict receipt is denied"

# (2) close with an INVALID verdict (fails idc_review_verdict_check) ⇒ denied.
#     PASS verdict but carrying a major finding → the checker rejects it as inconsistent.
cat > "$REPO/bad-verdict.json" <<JSON
{"verdict":"PASS","pr":9,"issue":$n,
 "findings":[{"dimension":"correctness","severity":"major","confidence":0.95,"evidence":"e","attack":"a","unblock":"u","fingerprint":"fp"}]}
JSON
if eng close --num "$n" --verdict "$REPO/bad-verdict.json" --pr 9 2>/dev/null; then
  fail "(2) engine closed on a verdict that fails validation (guard must re-run the checker)"
fi
echo "  ok (2) close on an invalid verdict is denied"

# (3) a VALID code-reviews verdict with NO source-owned witness ⇒ denied.
cat > "$VERDICT" <<JSON
{"verdict":"PASS","pr":9,"issue":$n,"findings":[]}
JSON
if eng close --num "$n" --verdict "$VERDICT" --pr 9 2>/dev/null; then
  fail "(3) engine closed on a code-reviews verdict with NO validator-owned witness (a shaped PASS must not be enough)"
fi
echo "  ok (3) a valid code-reviews verdict without a source-owned witness is denied"

# (4) once the REAL validator has run and recorded its witness, the SAME verdict may close.
python3 "$CHECK" "$VERDICT" >/dev/null 2>&1 || fail "(4) validator did not accept the good code-reviews verdict"
eng close --num "$n" --verdict "$VERDICT" --pr 9 >/dev/null 2>&1 \
  || fail "(4) engine denied a close backed by a VALID, item-owning, witnessed verdict receipt"
[ "$(gov_field "$T" "$n" Status)" = "Done" ] || fail "(4) valid witnessed close did not drive the item to Done"
echo "  ok (4) close backed by a valid, item-owning, witnessed verdict receipt succeeds"

echo "PASS: engine close requires a validated verdict receipt for the item, and a code-reviews verdict must also carry a source-owned validator witness (no receipt / invalid receipt / unwitnessed shaped PASS ⇒ denied; valid + owning + witnessed ⇒ Done)"
