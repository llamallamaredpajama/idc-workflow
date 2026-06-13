#!/bin/bash
# Phase 5 smoke — Ripple's deterministic doctrine:
#   (a) downstream sync set: changing layer N requires syncing N + every layer below it in
#       ONE PR (PRD->spec->master->subphase->pillar); and the gate fires iff the highest
#       affected layer is the PRD (user-facing function);
#   (b) the PRD path reuses the one gate (gate issue + a doc-dependent issue Blocked behind
#       it) over the real tracker; a non-PRD path creates NO gate.
# Failing-test-first: fails until scripts/idc_ripple_layers.py exists.
#
# Usage: bash tests/smoke/phase5-ripple.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
RL="$PLUGIN/scripts/idc_ripple_layers.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RL" ] || fail "ripple-layers helper not found at $RL (not implemented yet)"

# ---- (a) downstream sync set + gate decision -------------------------------------
# spec drift -> sync spec..pillar, no gate
out="$(python3 "$RL" spec)"
echo "$out" | grep -q "^sync: spec master subphase pillar$" || fail "spec drift sync set wrong: $out"
echo "$out" | grep -q "^gate: no$" || fail "spec drift must not gate"
# pillar drift -> sync pillar only, no gate
python3 "$RL" pillar | grep -q "^sync: pillar$" || fail "pillar drift sync set should be pillar only"
# prd drift -> sync everything, gate yes
out="$(python3 "$RL" prd)"
echo "$out" | grep -q "^sync: prd spec master subphase pillar$" || fail "prd drift sync set wrong: $out"
echo "$out" | grep -q "^gate: yes$" || fail "PRD drift MUST gate"
# unknown layer -> error
python3 "$RL" bogus >/dev/null 2>&1 && fail "unknown layer should error"

# ---- (b) PRD path reuses the one gate; non-PRD path creates no gate ---------------
T="$WORK/TRACKER.md"
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — ripple")
doc_issue=$(python3 "$TRK" --tracker "$T" create --title "Sync PRD-affected open issue")
python3 "$TRK" --tracker "$T" block --num "$doc_issue" --by "$gate" >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$doc_issue" --field Status)" = "Blocked" ] || fail "PRD-drift dependent should be Blocked behind the gate"

echo "PASS: ripple downstream-sync + PRD-only gate doctrine green"
