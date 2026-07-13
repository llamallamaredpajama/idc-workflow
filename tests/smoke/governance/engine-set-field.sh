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

echo "== set-field REFUSES Stage (a Stage change is a machine transition — use move; Fix 2) =="
# Round-4 Fix 2: set-field must NOT write the machine-governed Stage field. A raw Stage write reads
# neither the item's current Status nor the machine invariants, so it can mint the machine-illegal
# Stage/Status pair the shared guard forbids (e.g. In-Progress + Recirculation) and journals no
# to_stage (→ replay divergence). set-field is restricted to NON-machine single-selects; Stage → move.
if eng set-field --num "$n" --field Stage --value Recirculation >/dev/null 2>&1; then
  fail "set-field wrongly accepted a Stage write (must refuse — Stage is a machine transition, use move)"
fi
[ "$(gov_field "$T" "$n" Stage)" = "Buildable" ] || fail "the refused Stage set-field still mutated Stage"
echo "  ok set-field refuses Stage (Stage stays Buildable)"

echo "== github: set-field drives set_single_select AND positively reads the written value back (Fix 2) =="
python3 - "$GOV_PLUGIN/scripts" "$REPO" <<'PY' || fail "github set-field unit failed (see above)"
import sys
sys.path.insert(0, sys.argv[1])
repo = sys.argv[2]
import idc_transition as E, idc_gh_board as B
ctx = E.github_ctx(repo, "o", "1", itemid_cache={5: "PVTI_5"})

# ---- positive: the write lands and the read-back CONFIRMS it (fetch_item MUST be consulted) ----
calls, reads = [], []
B.set_single_select = lambda owner, project, r, item_id, field, value: calls.append((item_id, field, value))
def _readback_ok(item_id, r):
    reads.append(item_id)
    return {"domain": "core", "stage": "Buildable", "status": "Todo"}   # the write is reflected
B.fetch_item = _readback_ok
E.run("set-field", ctx, num=5, field="Domain", value="core")
assert calls == [("PVTI_5", "Domain", "core")], f"set-field did not drive set_single_select: {calls}"
assert reads, "set-field did NOT read the field back (no fetch_item call) — the readback is missing"
print("  ok github set-field drives set_single_select AND reads the written value back to confirm it")

# ---- red-when-broken: a NO-OP setter + a read-back that does NOT match the request must FAIL ----
# If set-field skipped the positive read-back, this no-op write would be reported as success.
calls2, reads2 = [], []
B.set_single_select = lambda *a, **k: calls2.append(a)          # NO-OP: pretends to write, changes nothing
def _readback_wrong(item_id, r):
    reads2.append(item_id)
    return {"domain": "STILL_OLD", "stage": "Buildable", "status": "Todo"}   # the request ("core") did NOT land
B.fetch_item = _readback_wrong
try:
    E.run("set-field", ctx, num=5, field="Domain", value="core")
    print("FAIL: set-field reported success when the read-back value did not match the request"); sys.exit(1)
except E.TransitionError:
    pass
assert reads2, "set-field did NOT read back on the mismatch path either — the readback is missing"
print("  ok a no-op write with a non-matching read-back makes set-field FAIL (readback is real, not decorative)")

# ---- read-back cannot be read at all → also a hard failure (never a blind success) ----
def _readback_raises(item_id, r):
    raise B.BoardReadError("simulated read-back failure")
B.fetch_item = _readback_raises
try:
    E.run("set-field", ctx, num=5, field="Domain", value="core")
    print("FAIL: set-field reported success when the read-back could not be read"); sys.exit(1)
except (E.TransitionError, B.BoardReadError):
    pass
print("  ok an unreadable read-back makes set-field FAIL")

# ---- Status AND Stage are refused (machine transitions — use move); an unknown field is refused ----
# too, ALL before any board write (Fix 2: set-field owns only NON-machine single-selects).
B.fetch_item = _readback_ok
for bad_field in ("Status", "Stage", "Bogus"):
    n_before = len(calls)
    try:
        E.run("set-field", ctx, num=5, field=bad_field, value="Recirculation" if bad_field == "Stage" else "x")
        print(f"FAIL: github set-field accepted a {bad_field} write"); sys.exit(1)
    except E.TransitionError:
        pass
    assert len(calls) == n_before, f"set-field wrote {bad_field} to the board before refusing it"
print("  ok github set-field refuses Status, Stage, and an unknown field BEFORE writing")
PY

echo "PASS: set-field writes non-Status single-select fields through the single write door on both backends, positively reads the value back, and refuses Status / unknown fields"
