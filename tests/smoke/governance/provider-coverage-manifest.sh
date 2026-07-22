#!/bin/bash
# idc-assert-class: behavior
# Optional-provider coverage honesty (U3).
# Absence/failure of optional code evidence must report partial|unavailable, never masquerade as
# complete coverage / "no impact".
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
GRAPH="$PLUGIN/scripts/idc_execution_graph.py"
. "$PLUGIN/tests/smoke/governance/lib.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$GRAPH" ] || fail "idc_execution_graph.py not found at $GRAPH (provider coverage manifest not implemented yet)"

cat > "$WORK/matrix.yaml" <<'YAML'
phase: Phase 1
pillars:
  - id: alpha
    wave: 1
    domain: core
    surfaces: [src/alpha/]
    blocks_on: []
YAML
T="$(gov_new_tracker)" || fail "could not init a throwaway TRACKER.md"

python3 "$GRAPH" --matrix "$WORK/matrix.yaml" --backend filesystem --tracker "$T" --json > "$WORK/unavailable.json" \
  || fail "graph compiler rejected the default unavailable-provider case"
python3 - "$WORK/unavailable.json" <<'PY' || exit 1
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
cov = data.get('coverage_manifest') or {}
status = cov.get('status')
if status not in {'partial', 'unavailable'}:
    raise SystemExit(f"FAIL: unavailable optional provider must report partial|unavailable, got {status!r}")
if cov.get('code_evidence_complete') is not False:
    raise SystemExit(f"FAIL: unavailable optional provider must not claim complete code evidence, got {cov}")
providers = cov.get('providers') or []
if not providers or providers[0].get('status') != 'unavailable':
    raise SystemExit(f"FAIL: provider manifest must make the disabled/absent provider explicit, got {providers}")
if 'no impact' in json.dumps(cov).lower():
    raise SystemExit(f"FAIL: provider absence must never masquerade as 'no impact', got {cov}")
print('ok: unavailable optional provider is reported honestly')
PY

python3 "$GRAPH" --matrix "$WORK/matrix.yaml" --backend filesystem --tracker "$T" \
  --code-provider-name codegraph --code-provider-status complete-for-declared-scope --json > "$WORK/complete.json" \
  || fail "graph compiler rejected the explicit complete-provider case"
python3 - "$WORK/complete.json" <<'PY' || exit 1
import json, sys
path = sys.argv[1]
data = json.load(open(path, encoding='utf-8'))
cov = data.get('coverage_manifest') or {}
if cov.get('status') != 'complete-for-declared-scope':
    raise SystemExit(f"FAIL: explicit complete provider should report complete-for-declared-scope, got {cov.get('status')!r}")
if cov.get('code_evidence_complete') is not True:
    raise SystemExit(f"FAIL: explicit complete provider should mark code evidence complete, got {cov}")
providers = cov.get('providers') or []
if not providers or providers[0].get('name') != 'codegraph' or providers[0].get('status') != 'complete-for-declared-scope':
    raise SystemExit(f"FAIL: explicit provider manifest must preserve provider name/status, got {providers}")
print('ok: explicit complete provider is preserved exactly')
PY

echo "PASS: optional-provider coverage manifest is honest for unavailable and explicit-complete cases"
