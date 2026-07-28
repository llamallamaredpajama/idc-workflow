#!/bin/bash
# idc-assert-class: behavior
# Whole-horizon graph / projection determinism (U3).
# Proves three load-bearing properties:
#   (a) duplicate pillar ids are rejected fail-closed;
#   (b) normalized alias / directory-containment collisions are rejected (not treated as disjoint);
#   (c) the authoritative compiler is deterministic and derives Waves from dependencies/resources,
#       not from model-authored `wave:` literals in the matrix.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
MATRIX="$PLUGIN/scripts/idc_matrix_check.py"
GRAPH="$PLUGIN/scripts/idc_execution_graph.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$MATRIX" ] || fail "matrix checker not found at $MATRIX"
[ -f "$GRAPH" ] || fail "idc_execution_graph.py not found at $GRAPH (authoritative graph compiler not implemented yet)"

cat > "$WORK/dup.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: dup
    wave: 1
    domain: core
    surfaces: [src/dup-a/]
    blocks_on: []
  - id: dup
    wave: 2
    domain: core
    surfaces: [src/dup-b/]
    blocks_on: []
YAML
out="$(python3 "$MATRIX" "$WORK/dup.yaml" 2>&1)" \
  && fail "duplicate pillar ids were accepted (must reject)"
printf '%s\n' "$out" | grep -qiE 'duplicate|dup' \
  || fail "duplicate-id rejection must name the duplicate pillar id; got: $out"

cat > "$WORK/contain.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: owner-dir
    wave: 1
    domain: core
    surfaces: [./src/api/]
    blocks_on: []
  - id: owner-file
    wave: 1
    domain: core
    surfaces: [src//api/handlers.py]
    blocks_on: []
YAML
out="$(python3 "$MATRIX" "$WORK/contain.yaml" 2>&1)" \
  && fail "normalized alias / containment collision was accepted (must reject)"
printf '%s\n' "$out" | grep -qiE 'share surface|contain|alias|src/api' \
  || fail "normalized-collision rejection must explain the overlap; got: $out"

T="$(gov_new_tracker)" || fail "could not init a throwaway TRACKER.md"
cat > "$WORK/waves.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 99
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
  - id: beta
    wave: 1
    domain: core
    surfaces: [src/beta/]
    blocks_on: [alpha]
  - id: gamma
    wave: 42
    domain: core
    surfaces: [src/gamma/]
    blocks_on: []
YAML
python3 "$GRAPH" --matrix "$WORK/waves.yaml" --backend filesystem --tracker "$T" --json > "$WORK/out1.json" \
  || fail "authoritative graph compiler rejected a valid whole-horizon input"
python3 "$GRAPH" --matrix "$WORK/waves.yaml" --backend filesystem --tracker "$T" --json > "$WORK/out2.json" \
  || fail "authoritative graph compiler was not deterministic on a repeated run"
cmp -s "$WORK/out1.json" "$WORK/out2.json" \
  || fail "same input produced different graph/projection output on repeated runs"
python3 - "$WORK/out1.json" <<'PY' || exit 1
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
want = {'alpha': 1, 'beta': 2, 'gamma': 1}
if data.get('waves') != want:
    raise SystemExit(f"FAIL: derived Waves must ignore model-authored values and follow dependencies/resources; expected {want}, got {data.get('waves')}")
alpha = next((n for n in data.get('nodes', []) if n.get('id') == 'alpha'), None)
gamma = next((n for n in data.get('nodes', []) if n.get('id') == 'gamma'), None)
if not alpha or alpha.get('declared_wave') != 99:
    raise SystemExit(f"FAIL: compiler must preserve the authored wave as evidence (alpha declared_wave=99), got {alpha}")
if not gamma or gamma.get('declared_wave') != 42:
    raise SystemExit(f"FAIL: compiler must preserve the authored wave as evidence (gamma declared_wave=42), got {gamma}")
print('ok: deterministic derived Waves ignore authored wave literals')
PY

echo "PASS: duplicate ids fail; normalized alias/containment collisions fail; authoritative graph output is deterministic and derives Waves (not model-authored)"
