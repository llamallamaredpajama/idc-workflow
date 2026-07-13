#!/bin/bash
# engine-set-field.sh — governance scenario: the sanctioned `set-field` op writes a NON-Status
# single-select field through the single write door (Task 3, Fix 2).
#
# The hardened mutation interlock DENIES a raw `gh project item-edit` during an active command, so the
# non-Status field writes Plan performs (Wave/Phase/Domain) must go through a sanctioned engine op.
# `set-field` is that door; a Status change stays a transition (`move`), so set-field REFUSES Status.
#
# Filesystem-backend real run (the fs `set` primitive is exercised end-to-end) + a github-monkeypatched
# unit proving set-field drives the sanctioned idc_gh_board.set_single_select primitive, never a raw
# item-edit. Red-when-broken: drop the `field` kind branch / the fs `set` wiring → the value never
# lands → this FAILs.
#
# Usage: bash tests/smoke/governance/engine-set-field.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"
gov_engine_env

echo "== filesystem: set-field writes a non-Status field, verifiable via read-back =="
n="$(gov_seed_item "$T" --title 'wave target' --stage Buildable --status Todo)" \
  || fail "could not seed the target item"
eng set-field --num "$n" --field Wave --value W1 >/dev/null || fail "set-field Wave=W1 failed"
got="$(gov_field "$T" "$n" Wave)"
[ "$got" = "W1" ] || fail "set-field did not land: Wave is [$got], expected W1"
eng set-field --num "$n" --field Phase --value P2 >/dev/null || fail "set-field Phase=P2 failed"
[ "$(gov_field "$T" "$n" Phase)" = "P2" ] || fail "set-field Phase did not land"
echo "  ok set-field Wave/Phase land on the filesystem backend"

echo "== set-field REFUSES Status (a Status change is a transition — use move) =="
if eng set-field --num "$n" --field Status --value Done >/dev/null 2>&1; then
  fail "set-field wrongly accepted a Status write (must refuse — Status is a transition)"
fi
[ "$(gov_field "$T" "$n" Status)" = "Todo" ] || fail "the refused Status set-field still mutated Status"
echo "  ok set-field refuses Status (Status stays Todo)"

echo "== github: set-field drives the sanctioned set_single_select primitive, not a raw item-edit =="
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github set-field unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B

calls = []
B.set_single_select = lambda owner, project, r, item_id, field, value: calls.append((item_id, field, value))
def _readback(item_id, r):   # fetch_item after the write — Stage/Status untouched
    return {"stage": "Buildable", "status": "Todo"}
B.fetch_item = _readback
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

E.run("set-field", ctx, num=5, field="Domain", value="core")
assert calls == [("PVTI_5", "Domain", "core")], f"set-field did not drive set_single_select: {calls}"

try:
    E.run("set-field", ctx, num=5, field="Status", value="Done")
    print("FAIL: github set-field accepted a Status write"); sys.exit(1)
except E.TransitionError:
    pass
print("  ok github set-field drives set_single_select for a non-Status field and refuses Status")
PY

echo "PASS: set-field writes non-Status single-select fields through the single write door on both backends and refuses Status"
