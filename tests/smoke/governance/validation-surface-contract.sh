#!/bin/bash
# validation-surface-contract.sh — U6 surface/evidence validation-contract typing.
# Proves:
#   (a) a frozen contract records the declared surface/evidence pairing and the execution receipt carries
#       bounded/redacted declared evidence of that exact kind;
#   (b) a mismatched surface/evidence pair is refused;
#   (c) `surface:none` without a one-line skip_reason is refused;
#   (d) an impossible evidence kind for the declared commands is refused;
#   (e) a tampered execution receipt whose declared evidence kind drifts from the frozen contract is refused.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: surface/evidence typing is still absent"
[ -f "$BR" ] || fail "missing build receipt helper: declared-evidence drift is still accepted"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

setup_repo() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/src/allowed" \
           "$repo/docs/workflow/build-validation" \
           "$repo/docs/workflow/build-validation-executions" \
           "$repo/docs/workflow/build-receipts" \
           "$repo/docs/workflow/code-reviews"
  cat > "$repo/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
  chmod +x "$repo/verify.sh"
  printf 'old behavior\n' > "$repo/src/allowed/feature.txt"
  git -C "$repo" add verify.sh src/allowed/feature.txt
  git -C "$repo" commit -qm init
}

write_verdict_from_execution() {
  local execution="$1" verdict="$2"
  python3 - "$execution" "$verdict" <<'PY'
import json, sys
exec_path, verdict_path = sys.argv[1:3]
receipt = json.load(open(exec_path, encoding='utf-8'))
verdict = {
    'verdict': 'PASS',
    'issue': receipt['issue'],
    'pr': receipt['pr'],
    'head': receipt['head'],
    'diff_digest': receipt['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$verdict" >/dev/null 2>&1 || fail "review verdict validator rejected the generated validation-surface verdict"
}

# (A) Good CLI contract + bounded declared evidence carried into the execution receipt.
REPO_GOOD="$WORK/repo-good"
setup_repo "$REPO_GOOD"
CONTRACT_GOOD="$REPO_GOOD/docs/workflow/build-validation/cli.json"
EXEC_GOOD="$REPO_GOOD/docs/workflow/build-validation-executions/cli.json"
VERDICT_GOOD="$REPO_GOOD/docs/workflow/code-reviews/2026-07-23-pr-401-cli.json"
RECEIPT_GOOD="$REPO_GOOD/docs/workflow/build-receipts/cli.json"
python3 "$VC" freeze \
  --repo "$REPO_GOOD" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --surface cli \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label cli-surface \
  --out "$CONTRACT_GOOD" >/dev/null \
  || fail "a valid cli/pane-capture contract was rejected"
printf 'new behavior\n' > "$REPO_GOOD/src/allowed/feature.txt"
git -C "$REPO_GOOD" add src/allowed/feature.txt
git -C "$REPO_GOOD" commit -qm 'implement cli behavior'
python3 "$VC" run --repo "$REPO_GOOD" --contract "$CONTRACT_GOOD" --out "$EXEC_GOOD" >/dev/null \
  || fail "could not execute the frozen cli validation contract"
python3 - "$CONTRACT_GOOD" "$EXEC_GOOD" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
execution = json.load(open(sys.argv[2], encoding='utf-8'))
if contract.get('surface') != 'cli' or contract.get('evidence_kind') != 'pane-capture':
    raise SystemExit(f"FAIL: frozen contract did not record cli/pane-capture, got {contract.get('surface')!r} / {contract.get('evidence_kind')!r}")
if execution.get('surface') != 'cli' or execution.get('evidence_kind') != 'pane-capture':
    raise SystemExit(f"FAIL: execution receipt did not carry cli/pane-capture, got {execution.get('surface')!r} / {execution.get('evidence_kind')!r}")
declared = execution.get('declared_evidence') or {}
if declared.get('kind') != 'pane-capture':
    raise SystemExit(f"FAIL: execution receipt missing declared evidence kind, got {declared}")
records = declared.get('records') or []
if not records:
    raise SystemExit(f"FAIL: execution receipt must carry bounded evidence records, got {declared}")
for row in records:
    for key in ('stdout_excerpt', 'stderr_excerpt'):
        if len(str(row.get(key) or '')) > 400:
            raise SystemExit(f"FAIL: {key} exceeded the bounded evidence limit: {row.get(key)!r}")
print('ok: cli validation contract recorded its declared surface/evidence kind and bounded evidence')
PY
write_verdict_from_execution "$EXEC_GOOD" "$VERDICT_GOOD"
python3 "$BR" write \
  --repo "$REPO_GOOD" \
  --contract "$CONTRACT_GOOD" \
  --execution "$EXEC_GOOD" \
  --verdict "$VERDICT_GOOD" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_GOOD" >/dev/null \
  || fail "the matching cli implementation receipt was rejected"

# (B) A mismatched surface/evidence pair is refused.
REPO_PAIR="$WORK/repo-pair"
setup_repo "$REPO_PAIR"
out="$(python3 "$VC" freeze \
  --repo "$REPO_PAIR" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --surface api \
  --evidence-kind pane-capture \
  --baseline expected-red \
  --label pair-mismatch \
  --out "$WORK/pair-mismatch.json" 2>&1)" \
  && fail "a mismatched surface/evidence pair was accepted"
printf '%s\n' "$out" | grep -qiE 'surface|evidence|pair' \
  || fail "surface/evidence mismatch refusal must explain the pairing failure; got: $out"

# (C) `surface:none` without a one-line skip_reason is refused.
REPO_NONE="$WORK/repo-none"
git init -q -b main "$REPO_NONE"
git -C "$REPO_NONE" config user.email test@example.com
git -C "$REPO_NONE" config user.name tester
printf '# docs only\n' > "$REPO_NONE/README.md"
git -C "$REPO_NONE" add README.md
git -C "$REPO_NONE" commit -qm init
out="$(python3 "$VC" freeze \
  --repo "$REPO_NONE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch README.md \
  --off-limits docs/ \
  --surface none \
  --evidence-kind none \
  --baseline expected-green \
  --label docs-only \
  --out "$WORK/none-missing-reason.json" 2>&1)" \
  && fail "surface:none without a skip_reason was accepted"
printf '%s\n' "$out" | grep -qiE 'skip_reason|surface:none|one-line' \
  || fail "surface:none refusal must name the missing skip_reason; got: $out"

# (D) A valid `surface:none` contract records the one-line reason and zero commands.
CONTRACT_NONE="$REPO_NONE/docs-only.json"
python3 "$VC" freeze \
  --repo "$REPO_NONE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch README.md \
  --off-limits docs/ \
  --surface none \
  --evidence-kind none \
  --skip-reason 'docs-only change' \
  --baseline expected-green \
  --label docs-only \
  --out "$CONTRACT_NONE" >/dev/null \
  || fail "a valid surface:none contract was rejected"
python3 - "$CONTRACT_NONE" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
if contract.get('surface') != 'none' or contract.get('evidence_kind') != 'none':
    raise SystemExit(f"FAIL: surface:none contract recorded the wrong kind: {contract}")
if contract.get('skip_reason') != 'docs-only change':
    raise SystemExit(f"FAIL: surface:none contract lost its one-line skip_reason: {contract.get('skip_reason')!r}")
if contract.get('verification') not in ([], None):
    raise SystemExit(f"FAIL: surface:none contract must not carry runnable verification commands: {contract.get('verification')!r}")
print('ok: surface:none requires and preserves a one-line skip_reason')
PY

# (E) Declared commands that cannot produce the evidence kind are refused.
REPO_IMPOSSIBLE="$WORK/repo-impossible"
setup_repo "$REPO_IMPOSSIBLE"
out="$(python3 "$VC" freeze \
  --repo "$REPO_IMPOSSIBLE" \
  --issue 1 \
  --pr 401 \
  --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ \
  --off-limits docs/ \
  --verify 'bash verify.sh' \
  --surface gui \
  --evidence-kind screenshot-or-recording \
  --baseline expected-red \
  --label impossible-evidence \
  --out "$WORK/impossible-evidence.json" 2>&1)" \
  && fail "an impossible evidence kind for the declared commands was accepted"
printf '%s\n' "$out" | grep -qiE 'cannot produce|evidence|screenshot|recording' \
  || fail "impossible-evidence refusal must explain the producibility failure; got: $out"

# (F) A tampered execution receipt whose declared evidence kind drifts from the frozen contract is refused.
FORGED_EXEC="$REPO_GOOD/docs/workflow/build-validation-executions/forged-surface.json"
python3 - "$EXEC_GOOD" "$FORGED_EXEC" <<'PY'
import hashlib, json, sys
src, dst = sys.argv[1:3]
execution = json.load(open(src, encoding='utf-8'))
execution['evidence_kind'] = 'response-body'
execution['declared_evidence']['kind'] = 'response-body'
body = dict(execution)
body.pop('execution_digest', None)
blob = json.dumps(body, sort_keys=True, separators=(',', ':')).encode('utf-8')
execution['execution_digest'] = hashlib.sha256(blob).hexdigest()
with open(dst, 'w', encoding='utf-8') as fh:
    json.dump(execution, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
out="$(python3 "$BR" write \
  --repo "$REPO_GOOD" \
  --contract "$CONTRACT_GOOD" \
  --execution "$FORGED_EXEC" \
  --verdict "$VERDICT_GOOD" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/forged-surface-receipt.json" 2>&1)" \
  && fail "an execution receipt whose declared evidence kind drifted from the frozen contract was accepted"
printf '%s\n' "$out" | grep -qiE 'contract-drift|surface|evidence kind|declared evidence' \
  || fail "declared-evidence drift refusal must explain the frozen-contract mismatch; got: $out"

echo "PASS: validation contracts type the fixed surface/evidence table, require surface:none reasons, reject impossible evidence, and refuse declared-evidence drift"