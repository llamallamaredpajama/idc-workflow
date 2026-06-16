#!/bin/bash
# Phase 5 smoke — the Recirculator's deterministic doctrine:
#   (a) downstream sync set: changing layer N requires syncing N + every layer below it in
#       ONE PR (PRD->spec->master->subphase->pillar); and the gate fires ONLY on a requirements
#       layer (the PRD always; the TRD/`spec` layer when gating.trd is on) — never on a
#       downstream/decomposition layer (master/subphase/pillar);
#   (a2) the TRD-gating toggle (U2): spec drift gates iff gating.trd is on;
#   (b) the requirements path reuses the ONE gate fired at the end of Think (the Think PR /
#       `idc:idc-gate-issue`); a non-requirements path creates NO gate. The Recirculator routes a
#       requirements-change backflow to that same gate (it does not own a second gate).
# Failing-test-first: fails until scripts/idc_recirculator_layers.py exists.
#
# Usage: bash tests/smoke/phase5-ripple.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
RL="$PLUGIN/scripts/idc_recirculator_layers.py"
TRK="$PLUGIN/scripts/idc_tracker_fs.py"
RECIRC="$PLUGIN/agents/idc-recirculator.md"
WORKFLOW="$PLUGIN/templates/WORKFLOW.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$RL" ] || fail "recirculator-layers helper not found at $RL (not implemented yet)"

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

# the gate fires on REQUIREMENTS ADMISSION only — a downstream/decomposition layer
# (master/subphase/pillar) MUST NOT gate even with every toggle on. This is the guard that fails
# red if the gate is ever made to fire on a non-requirements change.
CFG_ON="$WORK/cfg-trd-on.yaml";  printf 'gating:\n  prd: on\n  trd: on\n'  > "$CFG_ON"
CFG_OFF="$WORK/cfg-trd-off.yaml"; printf 'gating:\n  prd: on\n  trd: off\n' > "$CFG_OFF"
for ds in master subphase pillar; do
  python3 "$RL" "$ds" --config "$CFG_ON" | grep -q "^gate: no$" \
    || fail "the gate must fire on requirements admission only — a '$ds' (downstream) change must NEVER gate, even with trd:on"
done

# ---- (a2) TRD-gating toggle: spec drift gates iff gating.trd is on (U2) ------------
# The `spec` layer IS the TRD. With gating.trd:on it now reaches the gate; with :off it stays
# autonomous (greenfield default). The PRD always gates regardless of the TRD toggle.
python3 "$RL" spec --config "$CFG_ON" | grep -q "^gate: yes$" \
  || fail "TRD toggle: spec drift MUST gate when gating.trd is on"
python3 "$RL" spec --config "$CFG_OFF" | grep -q "^gate: no$" \
  || fail "TRD toggle: spec drift must stay ungated when gating.trd is off"
python3 "$RL" prd --config "$CFG_OFF" | grep -q "^gate: yes$" \
  || fail "TRD toggle: PRD MUST always gate regardless of the TRD toggle"
# default (no --config) preserves greenfield: spec ungated, prd gated (asserted in (a) above).

# ---- (b) requirements path reuses the ONE (Think-PR) gate; non-requirements path: no gate -----
T="$WORK/TRACKER.md"
python3 "$TRK" --tracker "$T" init || fail "tracker init failed"
gate=$(python3 "$TRK" --tracker "$T" create --title "[operator-action] PRD change — recirculate")
doc_issue=$(python3 "$TRK" --tracker "$T" create --title "Sync requirements-affected open issue")
python3 "$TRK" --tracker "$T" block --num "$doc_issue" --by "$gate" >/dev/null
[ "$(python3 "$TRK" --tracker "$T" show --num "$doc_issue" --field Status)" = "Blocked" ] || fail "requirements-drift dependent should be Blocked behind the gate"

# the Recirculator REUSES the one gate (it does not own a second one): its gated backflow routes to
# the same `idc:idc-gate-issue` mechanism Think fires at the end of Think (the Think PR).
[ -f "$RECIRC" ] || fail "agents/idc-recirculator.md missing"
grep -qF 'idc:idc-gate-issue' "$RECIRC" \
  || fail "the Recirculator must route a requirements-change backflow to the one gate (idc:idc-gate-issue)"
grep -qiE 'Think PR' "$RECIRC" \
  || fail "the Recirculator's gated backflow must reuse the gate fired at the end of Think (the Think PR)"
# WORKFLOW.md §2 must describe the one gate as the Think-PR requirements gate (anchor §2 kept).
[ -f "$WORKFLOW" ] || fail "templates/WORKFLOW.md missing"
grep -qiE 'Think PR' "$WORKFLOW" \
  || fail "WORKFLOW.md must describe the one gate as the Think PR (requirements admission at the end of Think)"

echo "PASS: recirculation downstream-sync + requirements-only gate doctrine + Think-PR gate reuse green"
