#!/bin/bash
# idc-assert-class: behavior
# Frozen projection + pure simulation (U3).
# Proves:
#   (a) simulation is pure (no tracker mutation);
#   (b) `In Progress` work is immutable in projected state;
#   (c) a live Buildable in the planning horizon cannot be absent from the graph/projection.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
PROJECTION="$PLUGIN/scripts/idc_tracker_projection.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$PROJECTION" ] || fail "idc_tracker_projection.py not found at $PROJECTION (frozen projection / simulator not implemented yet)"

cat > "$WORK/clean.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 11
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
  - id: beta
    wave: 1
    domain: core
    surfaces: [src/beta/]
    blocks_on: [alpha]
YAML
T="$(gov_new_tracker)" || fail "could not init a throwaway TRACKER.md"
before="$(shasum -a 256 "$T" | awk '{print $1}')"
python3 "$PROJECTION" --matrix "$WORK/clean.yaml" --backend filesystem --tracker "$T" --json > "$WORK/sim.json" \
  || fail "pure simulation rejected a valid planning input"
after="$(shasum -a 256 "$T" | awk '{print $1}')"
[ "$before" = "$after" ] \
  || fail "pure simulation mutated the live tracker (checksum changed $before -> $after)"
python3 - "$WORK/sim.json" <<'PY' || exit 1
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
actions = data.get('action_plan') or []
if not actions:
    raise SystemExit('FAIL: simulation must emit an action_plan for new Buildables on an empty tracker')
if data.get('simulation', {}).get('mutated_live_tracker'):
    raise SystemExit(f"FAIL: simulation must remain pure/read-only, got {data.get('simulation')}")
print('ok: pure simulation emitted a frozen action plan without mutating the tracker')
PY

T_IMM="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for In Progress immutability case"
alpha_num="$(gov_seed_item "$T_IMM" --title alpha --stage Buildable --status "In Progress" --wave 7 --phase "Phase 1" --domain core)" \
  || fail "could not seed In Progress Buildable"
cat > "$WORK/inprogress-mutate.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: other-domain
    surfaces: [src/alpha/]
    blocks_on: []
YAML
out="$(python3 "$PROJECTION" --matrix "$WORK/inprogress-mutate.yaml" --backend filesystem --tracker "$T_IMM" --json 2>&1)" \
  && fail "projection accepted an 'In Progress' mutation (must reject immutable occupancy)"
printf '%s\n' "$out" | grep -qiE 'In Progress|immutable|alpha' \
  || fail "In Progress mutation rejection must name the immutable item; got: $out"
[ "$(gov_field "$T_IMM" "$alpha_num" Status)" = "In Progress" ] \
  || fail "denied In Progress projection still mutated the tracker item's Status"
[ "$(gov_field "$T_IMM" "$alpha_num" Domain)" = "core" ] \
  || fail "denied In Progress projection still mutated the tracker item's Domain"

T_ROGUE="$(gov_new_tracker)" || fail "could not init throwaway TRACKER.md for rogue live item case"
rogue_num="$(gov_seed_item "$T_ROGUE" --title rogue-live --stage Buildable --status Todo --wave 1 --phase "Phase 1" --domain core)" \
  || fail "could not seed rogue live Buildable"
cat > "$WORK/rogue-live.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: planned-only
    wave: 1
    domain: core
    surfaces: [src/planned-only/]
    blocks_on: []
YAML
out="$(python3 "$PROJECTION" --matrix "$WORK/rogue-live.yaml" --backend filesystem --tracker "$T_ROGUE" --json 2>&1)" \
  && fail "projection accepted a live planning-horizon Buildable absent from the graph (must fail closed)"
printf '%s\n' "$out" | grep -qiE 'rogue-live|absent from the graph|planning horizon' \
  || fail "live-item parity failure must name the absent graph member; got: $out"
[ "$(gov_field "$T_ROGUE" "$rogue_num" Status)" = "Todo" ] \
  || fail "denied live-item parity check still mutated the tracker item's Status"

echo "PASS: projection simulation is pure; In Progress work is immutable; live planning-horizon Buildables absent from the graph fail closed"
