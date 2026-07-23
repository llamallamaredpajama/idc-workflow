#!/bin/bash
# build-stale-proof-refusal.sh — U6 stale / forged implementation-proof refusal contract.
# Proves refusal for:
#   (a) wrong issue or PR;
#   (b) verification run against stale code;
#   (c) review of a different diff;
#   (d) caller-authored / forged execution results;
#   (e) stale graph/projection evidence.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper: Build still accepts unverifiable execution claims"
[ -f "$BR" ] || fail "missing build receipt helper: stale or forged implementation proof is still accepted"

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

freeze_contract() {
  local repo="$1" contract="$2"
  python3 "$VC" freeze \
    --repo "$repo" \
    --issue 1 \
    --pr 301 \
    --graph-node alpha \
    --graph-digest "$GRAPH_DIGEST" \
    --projection-digest "$PROJECTION_DIGEST" \
    --touch src/allowed/ \
    --off-limits docs/ \
    --verify 'bash verify.sh' \
    --baseline expected-red \
    --label stale-proof \
    --out "$contract" >/dev/null
}

write_verdict_from_execution() {
  local execution="$1" verdict="$2" issue="$3" pr="$4" head_mode="$5" diff_mode="$6"
  python3 - "$execution" "$verdict" "$issue" "$pr" "$head_mode" "$diff_mode" <<'PY'
import json, sys
exec_path, verdict_path, issue, pr, head_mode, diff_mode = sys.argv[1:7]
receipt = json.load(open(exec_path, encoding='utf-8'))
head = receipt['head'] if head_mode == 'match' else '0' * 40
if diff_mode == 'match':
    diff_digest = receipt['diff_digest']
else:
    diff_digest = 'f' * 64
verdict = {
    'verdict': 'PASS',
    'issue': int(issue),
    'pr': int(pr),
    'head': head,
    'diff_digest': diff_digest,
    'findings': [],
}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  python3 "$CHECK" "$verdict" >/dev/null 2>&1 || fail "review verdict validator rejected the generated stale-proof verdict"
}

# Shared good repo for the stale/forged proof cases.
REPO="$WORK/repo"
setup_repo "$REPO"
CONTRACT="$REPO/docs/workflow/build-validation/contract.json"
EXECUTION="$REPO/docs/workflow/build-validation-executions/execution.json"
VERDICT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-301-review.json"
RECEIPT="$REPO/docs/workflow/build-receipts/receipt.json"
freeze_contract "$REPO" "$CONTRACT" || fail "could not freeze the stale-proof contract"
printf 'new behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'implement feature'
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXECUTION" >/dev/null \
  || fail "could not execute the frozen validation gate on the good implementation"
write_verdict_from_execution "$EXECUTION" "$VERDICT" 1 301 match match
python3 "$BR" write \
  --repo "$REPO" \
  --contract "$CONTRACT" \
  --execution "$EXECUTION" \
  --verdict "$VERDICT" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT" >/dev/null \
  || fail "shared good receipt setup failed"

# (A) wrong issue / PR is refused.
WRONG_ISSUE="$REPO/docs/workflow/code-reviews/2026-07-22-pr-301-wrong-issue.json"
write_verdict_from_execution "$EXECUTION" "$WRONG_ISSUE" 999 301 match match
out="$(python3 "$BR" write \
  --repo "$REPO" \
  --contract "$CONTRACT" \
  --execution "$EXECUTION" \
  --verdict "$WRONG_ISSUE" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/wrong-issue.json" 2>&1)" \
  && fail "a build receipt was accepted for the wrong issue"
printf '%s\n' "$out" | grep -qiE 'wrong issue|issue mismatch|owns the item' \
  || fail "wrong-issue refusal must explain the mismatch; got: $out"

WRONG_PR="$REPO/docs/workflow/code-reviews/2026-07-22-pr-301-wrong-pr.json"
write_verdict_from_execution "$EXECUTION" "$WRONG_PR" 1 999 match match
out="$(python3 "$BR" write \
  --repo "$REPO" \
  --contract "$CONTRACT" \
  --execution "$EXECUTION" \
  --verdict "$WRONG_PR" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/wrong-pr.json" 2>&1)" \
  && fail "a build receipt was accepted for the wrong PR"
printf '%s\n' "$out" | grep -qiE 'wrong pr|pr mismatch|owns the pr' \
  || fail "wrong-PR refusal must explain the mismatch; got: $out"

# (B) verification run against stale code is refused.
printf 'new behavior\n# later drift\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'later drift after verification'
CURRENT_VERDICT="$REPO/docs/workflow/code-reviews/2026-07-22-pr-301-current.json"
python3 - "$CONTRACT" "$CURRENT_VERDICT" <<'PY'
import hashlib, json, subprocess, sys
contract_path, verdict_path = sys.argv[1:3]
contract = json.load(open(contract_path, encoding='utf-8'))
repo = contract['repo']
base = contract['base_commit']
head = subprocess.check_output(['git', '-C', repo, 'rev-parse', 'HEAD'], text=True).strip()
diff = subprocess.check_output(['git', '-C', repo, 'diff', '--binary', f'{base}...HEAD'])
digest = hashlib.sha256(diff).hexdigest()
verdict = {'verdict': 'PASS', 'issue': 1, 'pr': 301, 'head': head, 'diff_digest': digest, 'findings': []}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
python3 "$CHECK" "$CURRENT_VERDICT" >/dev/null 2>&1 || fail "validator rejected the current-head verdict"
out="$(python3 "$BR" write \
  --repo "$REPO" \
  --contract "$CONTRACT" \
  --execution "$EXECUTION" \
  --verdict "$CURRENT_VERDICT" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/stale-execution.json" 2>&1)" \
  && fail "a stale verification execution receipt was accepted after the code changed"
printf '%s\n' "$out" | grep -qiE 'stale execution|verification run against stale code|head mismatch|diff digest mismatch' \
  || fail "stale-execution refusal must explain the changed code; got: $out"

# (C) review of a different diff is refused.
REPO_REVIEW="$WORK/repo-review-stale"
setup_repo "$REPO_REVIEW"
CONTRACT_REVIEW="$REPO_REVIEW/docs/workflow/build-validation/contract.json"
EXEC_REVIEW="$REPO_REVIEW/docs/workflow/build-validation-executions/execution.json"
VERDICT_REVIEW="$REPO_REVIEW/docs/workflow/code-reviews/2026-07-22-pr-301-review.json"
freeze_contract "$REPO_REVIEW" "$CONTRACT_REVIEW" || fail "could not freeze review-stale contract"
printf 'new behavior\n' > "$REPO_REVIEW/src/allowed/feature.txt"
git -C "$REPO_REVIEW" add src/allowed/feature.txt
git -C "$REPO_REVIEW" commit -qm 'implement feature'
python3 "$VC" run --repo "$REPO_REVIEW" --contract "$CONTRACT_REVIEW" --out "$EXEC_REVIEW" >/dev/null \
  || fail "could not execute the validation gate for the review-stale case"
write_verdict_from_execution "$EXEC_REVIEW" "$VERDICT_REVIEW" 1 301 mismatch mismatch
out="$(python3 "$BR" write \
  --repo "$REPO_REVIEW" \
  --contract "$CONTRACT_REVIEW" \
  --execution "$EXEC_REVIEW" \
  --verdict "$VERDICT_REVIEW" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/review-stale.json" 2>&1)" \
  && fail "a review bound to a different diff was accepted"
printf '%s\n' "$out" | grep -qiE 'review.*different diff|review.*head|review.*diff digest' \
  || fail "review-stale refusal must explain the mismatched review binding; got: $out"

# (D) caller-authored / forged execution result is refused.
FORGED_EXEC="$REPO_REVIEW/docs/workflow/build-validation-executions/forged.json"
python3 - "$EXEC_REVIEW" "$FORGED_EXEC" <<'PY'
import json, sys
src, dst = sys.argv[1:3]
receipt = json.load(open(src, encoding='utf-8'))
receipt['written_by'] = 'idc_validation_contract.py'
with open(dst, 'w', encoding='utf-8') as fh:
    json.dump(receipt, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
GOOD_VERDICT_REVIEW="$REPO_REVIEW/docs/workflow/code-reviews/2026-07-22-pr-301-good.json"
write_verdict_from_execution "$EXEC_REVIEW" "$GOOD_VERDICT_REVIEW" 1 301 match match
out="$(python3 "$BR" write \
  --repo "$REPO_REVIEW" \
  --contract "$CONTRACT_REVIEW" \
  --execution "$FORGED_EXEC" \
  --verdict "$GOOD_VERDICT_REVIEW" \
  --graph-digest "$GRAPH_DIGEST" \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/forged-execution.json" 2>&1)" \
  && fail "a caller-authored forged execution result was accepted"
printf '%s\n' "$out" | grep -qiE 'source-owned|witness|forged execution|execution receipt' \
  || fail "forged-execution refusal must explain the missing machine witness; got: $out"

# (E) stale graph / projection evidence is refused.
out="$(python3 "$BR" write \
  --repo "$REPO_REVIEW" \
  --contract "$CONTRACT_REVIEW" \
  --execution "$EXEC_REVIEW" \
  --verdict "$GOOD_VERDICT_REVIEW" \
  --graph-digest 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  --projection-digest "$PROJECTION_DIGEST" \
  --out "$WORK/stale-graph.json" 2>&1)" \
  && fail "stale graph/projection evidence was accepted"
printf '%s\n' "$out" | grep -qiE 'graph|projection|stale' \
  || fail "stale graph/projection refusal must explain the mismatch; got: $out"

echo "PASS: build receipt creation refuses wrong issue/PR, stale verification, stale review, forged execution results, and stale graph/projection evidence"