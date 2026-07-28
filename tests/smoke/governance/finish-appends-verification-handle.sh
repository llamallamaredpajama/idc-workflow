#!/bin/bash
# idc-assert-class: behavior
# finish-appends-verification-handle.sh — the COMPOUNDING half of the verification-handle design.
#
# Plan resolves reusable recipes by lookup; nothing ever wrote one back, so the registry could only
# ever hold what an operator hand-typed. Every triplet that figured out how to drive a new surface
# threw that knowledge away, and the next Plan re-derived it — the exact redundant-script failure the
# pilot-acceptance list worries about. `idc_verification_handles.py append` closes it as FIXED CODE
# writing IN PLACE on the ticket's branch, so the new recipe arrives as an ordinary tracked doc diff
# through the normal PR path, never a side-channel write.
#
# Proves:
#   (i)   after a handle-LESS contract executes green, `append --from-execution` records an entry
#         whose verify_commands are exactly the commands that were EXECUTED;
#   (ii)  the resulting file re-validates under `idc_schema_check.py registry` and resolves;
#   (iii) a duplicate handle_id AND a secret-bearing recipe are both refused, leaving the file byte-
#         identical;
#   (iv)  the write lands as an ordinary tracked file change (git sees a modified, staged-able file);
#   (v)   agents/idc-finisher.md still names the append step, before the build-receipt mint.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
VH="$PLUGIN/scripts/idc_verification_handles.py"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
FINISHER="$PLUGIN/agents/idc-finisher.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VC" ] || fail "missing build validation helper at $VC"
[ -f "$VH" ] || fail "missing verification-handle helper at $VH"
[ -f "$FINISHER" ] || fail "agents/idc-finisher.md not found at $FINISHER"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/src/allowed" "$REPO/docs/workflow/build-validation" \
         "$REPO/docs/workflow/build-validation-executions"
cat > "$REPO/drive-surface.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO/drive-surface.sh"
printf 'old behavior\n' > "$REPO/src/allowed/feature.txt"
# The scaffolded registry template: schema-valid, and EMPTY — the state every governed repo starts in.
cat > "$REPO/docs/workflow/verification-handles.yaml" <<'YAML'
# verification-handles.yaml — governed verification-surface registry
# (this header comment must survive an append)
schema_version: 1
handles: []
YAML
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

# A handle-LESS contract: this triplet is the first to drive this surface, so there is nothing to cite.
CONTRACT="$REPO/docs/workflow/build-validation/first.json"
EXEC="$REPO/docs/workflow/build-validation-executions/first.json"
python3 "$VC" freeze \
  --repo "$REPO" --issue 7 --pr 707 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --evidence-kind pane-capture --verify 'bash drive-surface.sh' \
  --baseline expected-red --label first-of-its-kind --out "$CONTRACT" >/dev/null \
  || fail "could not freeze the handle-less contract"
printf 'new behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'implement the behavior'
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXEC" >/dev/null \
  || fail "could not execute the handle-less contract"

REG="$REPO/docs/workflow/verification-handles.yaml"

# (iii-a) Refusals FIRST, against the pre-append file, so a refusal can never be mistaken for a
#         side effect of the successful append below.
cp "$REG" "$WORK/registry.before"
set +e
out="$(python3 "$VH" append --repo "$REPO" --handle-id 'cli-first-drive' --surface cli \
        --verify-command "curl -H 'Authorization: Bearer ghp_012345678901234567890123456789012345' http://localhost:1/x" 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a secret-bearing recipe was appended to the governed registry"
printf '%s\n' "$out" | grep -qiE 'secret|credential|auth' \
  || fail "the secret-bearing refusal must say what it found; got: $out"
cmp -s "$REG" "$WORK/registry.before" \
  || fail "a REFUSED append still modified the registry on disk"

# (i) The real append: surface, evidence kind and verify_commands all derived from the PROVEN run.
python3 "$VH" append --repo "$REPO" --handle-id 'cli-first-drive' --from-execution "$EXEC" \
  --fixture 'seed:none' >/dev/null \
  || fail "appending a newly-proven recipe from a passing execution receipt failed"

grep -qF 'this header comment must survive an append' "$REG" \
  || fail "the append rewrote the whole file and destroyed the operator's header comments"

python3 - "$PLUGIN/scripts" "$REG" "$EXEC" <<'PY' || exit 1
import json, sys
scripts, reg_path, exec_path = sys.argv[1:4]
sys.path.insert(0, scripts)
import idc_schema_check as SC
doc = SC.load_verification_registry(reg_path)
execution = json.load(open(exec_path, encoding='utf-8'))
executed = [row['command'] for row in execution['verification']]
handles = {h['handle_id']: h for h in doc['handles']}
if 'cli-first-drive' not in handles:
    raise SystemExit(f"FAIL: the proven recipe was not appended: {sorted(handles)}")
entry = handles['cli-first-drive']
if entry['verify_commands'] != executed:
    raise SystemExit(
        f"FAIL: the appended recipe does not record the EXECUTED commands "
        f"{executed!r}; got {entry['verify_commands']!r}")
if entry['surface'] != execution['surface'] or entry['evidence_kind'] != execution['evidence_kind']:
    raise SystemExit(
        f"FAIL: the appended recipe lost the proven surface/evidence pairing: {entry!r}")
print("ok: the appended recipe records exactly the commands the frozen gate actually ran")
PY

# (ii) The whole file re-validates through the fixed schema checker AND resolves through fixed code.
python3 "$SCHEMA" registry "$REG" >/dev/null \
  || fail "the registry no longer passes its own schema check after an append"
python3 "$VH" resolve --repo "$REPO" --handle-id 'cli-first-drive' --surface cli >/dev/null \
  || fail "the appended handle does not resolve through the fixed resolver"

# (iii-b) A duplicate id is refused, and the refusal leaves the file byte-identical.
cp "$REG" "$WORK/registry.after"
set +e
out="$(python3 "$VH" append --repo "$REPO" --handle-id 'cli-first-drive' --surface cli \
        --verify-command 'bash something-else.sh' 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a duplicate handle_id silently replaced an existing registry entry"
printf '%s\n' "$out" | grep -qF 'already exists' \
  || fail "the duplicate-id refusal must say the id already exists; got: $out"
cmp -s "$REG" "$WORK/registry.after" \
  || fail "a refused duplicate append still modified the registry on disk"

# (iv) The write is an ORDINARY TRACKED FILE CHANGE on the ticket's branch — reviewable and merged
#      through the normal PR path, not a side-channel write outside the diff.
status="$(git -C "$REPO" status --porcelain -- docs/workflow/verification-handles.yaml)"
printf '%s\n' "$status" | grep -qE '^ ?M' \
  || fail "the append did not show up as a modified TRACKED file (git status: '${status:-<empty>}')"
git -C "$REPO" add docs/workflow/verification-handles.yaml
git -C "$REPO" diff --cached --name-only | grep -qxF 'docs/workflow/verification-handles.yaml' \
  || fail "the appended registry cannot be staged into the ticket's own commit"

# (v) The shipped finisher playbook still names the append step, and names it BEFORE the build receipt
#     is minted — after the mint it would land outside the reviewed diff.
grep -qF 'idc_verification_handles.py' "$FINISHER" \
  || fail "agents/idc-finisher.md no longer names idc_verification_handles.py — the compounding step is gone"
grep -qE 'idc_verification_handles\.py"? append' "$FINISHER" \
  || fail 'agents/idc-finisher.md must name the append subcommand, not merely the helper'
python3 - "$FINISHER" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
def at(pattern):
    m = re.search(pattern, text)
    return m.start() if m else -1
append_at = at(r'idc_verification_handles\.py"?\s+append\b')
mint_at = at(r'idc_build_receipt\.py"?\s+write\b')
if append_at < 0 or mint_at < 0:
    raise SystemExit(f"FAIL: could not locate both steps in the finisher playbook "
                     f"(append={append_at}, mint={mint_at})")
if append_at > mint_at:
    raise SystemExit("FAIL: the finisher appends the proven recipe AFTER minting the build receipt — "
                     "the registry diff would then land outside the receipt-bound diff")
print("ok: the finisher appends the proven recipe before the build receipt is minted")
PY

echo "PASS: a newly-proven recipe is appended back to the governed registry by fixed code, records the executed commands, re-validates, refuses duplicates and secrets without touching the file, lands as a tracked diff, and is wired into the finisher before the receipt mint"
