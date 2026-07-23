#!/bin/bash
# frozen-gate-immutable.sh — U6 frozen validation-gate immutability.
# Proves a builder cannot edit the frozen contract after issuance: tampering the contract file causes
# contract execution to fail closed before any execution receipt is written.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: the builder can still change its own gate because no frozen contract exists"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/docs/workflow/build-validation" "$REPO/docs/workflow/build-validation-executions"
cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' feature.txt
SH
chmod +x "$REPO/verify.sh"
printf 'old behavior\n' > "$REPO/feature.txt"
git -C "$REPO" add feature.txt verify.sh
git -C "$REPO" commit -qm init

CONTRACT="$REPO/docs/workflow/build-validation/frozen.json"
python3 "$VC" freeze \
  --repo "$REPO" \
  --issue 1 \
  --pr 101 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch feature.txt \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --baseline expected-red \
  --label frozen-gate \
  --out "$CONTRACT" >/dev/null \
  || fail "could not freeze a valid build validation contract"

python3 - "$CONTRACT" <<'PY'
import json, sys
path = sys.argv[1]
contract = json.load(open(path, encoding='utf-8'))
contract['verification'][0]['command'] = 'true'
with open(path, 'w', encoding='utf-8') as fh:
    json.dump(contract, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY

EXECUTION="$REPO/docs/workflow/build-validation-executions/frozen.json"
out="$(python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXECUTION" 2>&1)" \
  && fail "a builder-edited frozen contract was accepted"
[ ! -e "$EXECUTION" ] || fail "tampered frozen contract still wrote an execution receipt"
printf '%s\n' "$out" | grep -qiE 'frozen|digest|witness|tamper|modified' \
  || fail "tampered frozen-gate refusal must explain the integrity failure; got: $out"

echo "PASS: the frozen build validation gate is immutable — editing it after issuance fails closed before execution"