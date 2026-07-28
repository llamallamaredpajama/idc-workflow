#!/bin/bash
# build-validation-baseline.sh — U6 baseline classification + frozen validation-contract contract.
# Proves:
#   (a) a missing behavior baseline freezes as expected-red;
#   (b) an already-satisfied baseline freezes as expected-green;
#   (c) claiming expected-red on an already-green baseline refuses before writing a contract.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: Build still has no frozen baseline contract"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

setup_repo() {
  local repo="$1" state="$2"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/docs/workflow/build-validation"
  cat > "$repo/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' feature.txt
SH
  chmod +x "$repo/verify.sh"
  printf '%s\n' "$state" > "$repo/feature.txt"
  git -C "$repo" add feature.txt verify.sh
  git -C "$repo" commit -qm init
}

# (A) expected-red baseline: the real verification command fails on missing behavior.
REPO_RED="$WORK/repo-red"
setup_repo "$REPO_RED" 'old behavior'
CONTRACT_RED="$REPO_RED/docs/workflow/build-validation/red.json"
python3 "$VC" freeze \
  --repo "$REPO_RED" \
  --issue 1 \
  --pr 101 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch feature.txt \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --baseline expected-red \
  --label build-red \
  --out "$CONTRACT_RED" >/dev/null \
  || fail "expected-red baseline freeze was refused on a real missing-behavior baseline"
python3 - "$CONTRACT_RED" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
base = contract.get('baseline') or {}
if base.get('expected') != 'expected-red' or base.get('actual') != 'expected-red':
    raise SystemExit(f"FAIL: expected-red contract must record expected-red/actual expected-red, got {base}")
results = base.get('results') or []
if not results or results[0].get('exit_code', 0) == 0:
    raise SystemExit(f"FAIL: expected-red contract must capture the failing baseline execution, got {results}")
if contract.get('written_by') != 'idc_validation_contract.py':
    raise SystemExit(f"FAIL: contract must be source-owned by idc_validation_contract.py, got {contract.get('written_by')!r}")
print('ok: expected-red baseline froze a real failing verification command')
PY

# (B) expected-green baseline: the exact no-delta baseline already satisfies the reused test.
REPO_GREEN="$WORK/repo-green"
setup_repo "$REPO_GREEN" 'new behavior'
CONTRACT_GREEN="$REPO_GREEN/docs/workflow/build-validation/green.json"
python3 "$VC" freeze \
  --repo "$REPO_GREEN" \
  --issue 1 \
  --pr 101 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch feature.txt \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --baseline expected-green \
  --label build-green \
  --out "$CONTRACT_GREEN" >/dev/null \
  || fail "expected-green baseline freeze was refused on an already-satisfied baseline"
python3 - "$CONTRACT_GREEN" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
base = contract.get('baseline') or {}
if base.get('expected') != 'expected-green' or base.get('actual') != 'expected-green':
    raise SystemExit(f"FAIL: expected-green contract must record expected-green/actual expected-green, got {base}")
results = base.get('results') or []
if not results or results[0].get('exit_code') != 0:
    raise SystemExit(f"FAIL: expected-green contract must capture the green baseline execution, got {results}")
print('ok: expected-green baseline froze an already-satisfied verification surface')
PY

# (C) unexpected-green refusal: asking for expected-red on an already-green baseline fails before write.
REPO_BAD="$WORK/repo-bad"
setup_repo "$REPO_BAD" 'new behavior'
CONTRACT_BAD="$REPO_BAD/docs/workflow/build-validation/unexpected-green.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO_BAD" \
  --issue 1 \
  --pr 101 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch feature.txt \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --baseline expected-red \
  --label build-unexpected-green \
  --out "$CONTRACT_BAD" 2>&1)" \
  && fail "unexpected-green baseline was accepted (must refuse before issuing a contract)"
[ ! -e "$CONTRACT_BAD" ] \
  || fail "unexpected-green refusal still wrote a frozen contract"
printf '%s\n' "$out" | grep -qi 'unexpected-green' \
  || fail "unexpected-green refusal must name the baseline mismatch; got: $out"

echo "PASS: build validation baselines classify expected-red/expected-green correctly and refuse unexpected-green before issuing the frozen contract"