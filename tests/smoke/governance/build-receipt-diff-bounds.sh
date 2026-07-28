#!/bin/bash
# build-receipt-diff-bounds.sh — U6 implementation-receipt diff + boundary binding.
# Proves:
#   (a) a valid implementation receipt can be written and re-verified for the exact final diff;
#   (b) a diff-digest mismatch is refused;
#   (c) an actual path outside `touch` is refused;
#   (d) an actual path inside `off-limits` is refused.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: no source-owned execution receipt exists yet"
[ -f "$BR" ] || fail "missing build receipt helper: the final diff is still unbound to the implementation receipt"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

setup_repo() {
  local repo="$1"
  git init -q -b main "$repo"
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name tester
  mkdir -p "$repo/src/allowed" "$repo/src/blocked" \
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
  printf 'do not touch\n' > "$repo/src/blocked/guard.txt"
  printf '# repo\n' > "$repo/README.md"
  git -C "$repo" add README.md verify.sh src/allowed/feature.txt src/blocked/guard.txt
  git -C "$repo" commit -qm init
}

freeze_contract() {
  local repo="$1" contract="$2"
  python3 "$VC" freeze \
    --repo "$repo" \
    --issue 1 \
    --pr 201 \
    --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --touch src/allowed/ \
    --off-limits src/blocked/ \
    --verify 'bash verify.sh' \
    --baseline expected-red \
    --label diff-bounds \
    --out "$contract" >/dev/null
}

make_verdict() {
  local repo="$1" exec_receipt="$2" verdict="$3"
  python3 - "$exec_receipt" "$verdict" <<'PY'
import json, sys
exec_path, verdict_path = sys.argv[1:3]
receipt = json.load(open(exec_path, encoding='utf-8'))
doc = {
    'verdict': 'PASS',
    'pr': 201,
    'issue': 1,
    'head': receipt['head'],
    'diff_digest': receipt['diff_digest'],
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$verdict" >/dev/null 2>&1 || fail "review verdict validator rejected the diff-bound good verdict"
}

write_good_receipt() {
  local repo="$1" contract="$2" execution="$3" verdict="$4" receipt="$5"
  python3 "$BR" write \
    --repo "$repo" \
    --contract "$contract" \
    --execution "$execution" \
    --verdict "$verdict" \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --out "$receipt" >/dev/null \
    || fail "a valid implementation receipt was rejected"
  python3 "$BR" verify --repo "$repo" --receipt "$receipt" >/dev/null \
    || fail "the freshly written implementation receipt did not re-verify"
}

# (A) Good path + diff-digest tamper refusal.
REPO_GOOD="$WORK/repo-good"
setup_repo "$REPO_GOOD"
CONTRACT_GOOD="$REPO_GOOD/docs/workflow/build-validation/good.json"
EXEC_GOOD="$REPO_GOOD/docs/workflow/build-validation-executions/good.json"
VERDICT_GOOD="$REPO_GOOD/docs/workflow/code-reviews/2026-07-22-pr-201-good.json"
RECEIPT_GOOD="$REPO_GOOD/docs/workflow/build-receipts/good.json"
freeze_contract "$REPO_GOOD" "$CONTRACT_GOOD" || fail "could not freeze the good validation contract"
printf 'new behavior\n' > "$REPO_GOOD/src/allowed/feature.txt"
git -C "$REPO_GOOD" add src/allowed/feature.txt
git -C "$REPO_GOOD" commit -qm 'implement allowed feature'
python3 "$VC" run --repo "$REPO_GOOD" --contract "$CONTRACT_GOOD" --out "$EXEC_GOOD" >/dev/null \
  || fail "could not execute the frozen validation gate on the good diff"
make_verdict "$REPO_GOOD" "$EXEC_GOOD" "$VERDICT_GOOD"
write_good_receipt "$REPO_GOOD" "$CONTRACT_GOOD" "$EXEC_GOOD" "$VERDICT_GOOD" "$RECEIPT_GOOD"

python3 - "$RECEIPT_GOOD" "$WORK/tampered-diff.json" <<'PY'
import json, sys
src, dst = sys.argv[1:3]
receipt = json.load(open(src, encoding='utf-8'))
receipt['diff_digest'] = '0' * 64
with open(dst, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
out="$(python3 "$BR" verify --repo "$REPO_GOOD" --receipt "$WORK/tampered-diff.json" 2>&1)" \
  && fail "a tampered implementation receipt with a mismatched diff digest was accepted"
printf '%s\n' "$out" | grep -qiE 'diff digest|mismatch|stale' \
  || fail "diff-digest refusal must explain the mismatch; got: $out"

# (B) Actual path outside `touch` is refused.
REPO_OUTSIDE="$WORK/repo-outside-touch"
setup_repo "$REPO_OUTSIDE"
CONTRACT_OUTSIDE="$REPO_OUTSIDE/docs/workflow/build-validation/outside.json"
EXEC_OUTSIDE="$REPO_OUTSIDE/docs/workflow/build-validation-executions/outside.json"
VERDICT_OUTSIDE="$REPO_OUTSIDE/docs/workflow/code-reviews/2026-07-22-pr-201-outside.json"
RECEIPT_OUTSIDE="$REPO_OUTSIDE/docs/workflow/build-receipts/outside.json"
freeze_contract "$REPO_OUTSIDE" "$CONTRACT_OUTSIDE" || fail "could not freeze outside-touch contract"
printf 'new behavior\n' > "$REPO_OUTSIDE/src/allowed/feature.txt"
printf 'outside touch\n' >> "$REPO_OUTSIDE/README.md"
git -C "$REPO_OUTSIDE" add src/allowed/feature.txt README.md
git -C "$REPO_OUTSIDE" commit -qm 'touch allowed file plus outside path'
python3 "$VC" run --repo "$REPO_OUTSIDE" --contract "$CONTRACT_OUTSIDE" --out "$EXEC_OUTSIDE" >/dev/null \
  || fail "could not execute the frozen validation gate for the outside-touch case"
make_verdict "$REPO_OUTSIDE" "$EXEC_OUTSIDE" "$VERDICT_OUTSIDE"
out="$(python3 "$BR" write \
  --repo "$REPO_OUTSIDE" \
  --contract "$CONTRACT_OUTSIDE" \
  --execution "$EXEC_OUTSIDE" \
  --verdict "$VERDICT_OUTSIDE" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_OUTSIDE" 2>&1)" \
  && fail "an implementation diff touching a path outside 'touch' was accepted"
printf '%s\n' "$out" | grep -qiE 'outside.*touch|not declared in touch|boundary' \
  || fail "outside-touch refusal must name the boundary violation; got: $out"

# (C) Actual path inside `off-limits` is refused.
REPO_OFF="$WORK/repo-off-limits"
setup_repo "$REPO_OFF"
CONTRACT_OFF="$REPO_OFF/docs/workflow/build-validation/off.json"
EXEC_OFF="$REPO_OFF/docs/workflow/build-validation-executions/off.json"
VERDICT_OFF="$REPO_OFF/docs/workflow/code-reviews/2026-07-22-pr-201-off.json"
RECEIPT_OFF="$REPO_OFF/docs/workflow/build-receipts/off.json"
freeze_contract "$REPO_OFF" "$CONTRACT_OFF" || fail "could not freeze off-limits contract"
printf 'new behavior\n' > "$REPO_OFF/src/allowed/feature.txt"
printf 'mutated\n' > "$REPO_OFF/src/blocked/guard.txt"
git -C "$REPO_OFF" add src/allowed/feature.txt src/blocked/guard.txt
git -C "$REPO_OFF" commit -qm 'touch allowed file plus off-limits path'
python3 "$VC" run --repo "$REPO_OFF" --contract "$CONTRACT_OFF" --out "$EXEC_OFF" >/dev/null \
  || fail "could not execute the frozen validation gate for the off-limits case"
make_verdict "$REPO_OFF" "$EXEC_OFF" "$VERDICT_OFF"
out="$(python3 "$BR" write \
  --repo "$REPO_OFF" \
  --contract "$CONTRACT_OFF" \
  --execution "$EXEC_OFF" \
  --verdict "$VERDICT_OFF" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT_OFF" 2>&1)" \
  && fail "an implementation diff touching an off-limits path was accepted"
printf '%s\n' "$out" | grep -qiE 'off-limits|forbidden path|boundary' \
  || fail "off-limits refusal must name the forbidden path; got: $out"

echo "PASS: implementation receipts bind to the exact final diff and fail closed on diff-digest drift, outside-touch writes, and off-limits writes"