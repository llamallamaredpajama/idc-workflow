#!/bin/bash
# idc-assert-class: behavior
# review-surface-precheck.sh — the review engine's DETERMINISTIC surface/evidence pre-check.
#
# The surface/evidence rules are fixed code at FREEZE (idc_validation_contract.py) and again at FINISH
# (idc_build_receipt.py). Review sits between them and had nothing but prose: SKILL.md described
# "contract drift" as a model-judgment dimension and never mentioned `surface`/`evidence_kind` at all,
# and `idc_review_verdict_check.py` carries no such rule. So the one stage whose whole job is catching
# this was the one stage forming an opinion about it, and any refusal only surfaced at merge time.
#
# Proves: the shipped review playbook routes the reviewer through the fixed helper and tells it to
# INHERIT the answer, and the helper itself passes an honest contract and refuses a drifted one.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
SKILL="$PLUGIN/skills/idc-review-engine/SKILL.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper at $VC"
[ -f "$SKILL" ] || fail "review-engine skill not found at $SKILL"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

# (A) The shipped playbook names the fixed pre-check and states that its answer is inherited.
python3 - "$SKILL" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
if not re.search(r'idc_validation_contract\.py"?\s+check-surface', text):
    raise SystemExit(
        "FAIL: skills/idc-review-engine/SKILL.md does not route the reviewer through "
        "`idc_validation_contract.py check-surface` — the surface/evidence rule is back to prose the "
        "reviewer has to judge by eye")
fences = re.findall(r"```bash\n(.*?)```", text, re.S)
if not any('check-surface' in f for f in fences):
    raise SystemExit(
        "FAIL: the check-surface invocation is not in a runnable ```bash fence in SKILL.md")
window = text[text.find('check-surface'):][:1600]
if 'contract-drift' not in window:
    raise SystemExit(
        "FAIL: SKILL.md does not say which dimension a check-surface refusal is filed under")
if not re.search(r'non-zero exit is a machine refusal', window):
    raise SystemExit(
        "FAIL: SKILL.md does not state that a non-zero exit is INHERITED as a refusal rather than "
        "treated as one more opinion — that sentence is the whole point of the pre-check")
print("ok: the review playbook routes surface/evidence typing through the fixed pre-check")
PY

# (B) The helper itself: an honest contract passes; a drifted execution receipt is refused by name.
REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/src/allowed" "$REPO/docs/workflow/build-validation" \
         "$REPO/docs/workflow/build-validation-executions"
cat > "$REPO/ci-verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO/ci-verify.sh"
printf 'old behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

CONTRACT="$REPO/docs/workflow/build-validation/pre.json"
EXEC="$REPO/docs/workflow/build-validation-executions/pre.json"
python3 "$VC" freeze \
  --repo "$REPO" --issue 9 --pr 909 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --evidence-kind pane-capture --verify 'bash ci-verify.sh' \
  --baseline expected-red --label precheck --out "$CONTRACT" >/dev/null \
  || fail "could not freeze the pre-check fixture contract"
printf 'new behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'implement behavior'
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXEC" >/dev/null \
  || fail "could not execute the pre-check fixture contract"

python3 "$VC" check-surface --contract "$CONTRACT" --execution "$EXEC" >/dev/null \
  || fail "the deterministic pre-check refused an honest contract/execution pair (control)"

# Drift the execution IN PLACE to a legal-but-different pairing and re-record its machine witness, so
# the only thing left to catch it is the pre-check's comparison against the frozen contract.
python3 - "$PLUGIN/scripts" "$EXEC" <<'PY' || fail "could not re-sign the drifted execution receipt"
import json, sys
scripts, target = sys.argv[1:3]
sys.path.insert(0, scripts)
import idc_validation_contract as VC
doc = json.load(open(target, encoding='utf-8'))
doc['surface'] = 'ci'
doc['evidence_kind'] = 'check-run'
doc['declared_evidence']['surface'] = 'ci'
doc['declared_evidence']['kind'] = 'check-run'
body = dict(doc); body.pop('execution_digest', None)
doc['execution_digest'] = VC.sha256_json(body)
VC.atomic_write_json(target, doc)
VC._record_witness('execution', target, doc)
PY
set +e
out="$(python3 "$VC" check-surface --contract "$CONTRACT" --execution "$EXEC" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "the deterministic pre-check passed an execution receipt that drifted from the frozen contract: $out"
printf '%s\n' "$out" | grep -qF "contract-drift refused: the execution receipt's declared surface/evidence kind no longer match the frozen validation contract" \
  || fail "the pre-check's refusal must be the verbatim contract-drift sentence a reviewer can file; got: $out"

echo "PASS: the review engine inherits a deterministic surface/evidence refusal from fixed code instead of forming an opinion about it"
