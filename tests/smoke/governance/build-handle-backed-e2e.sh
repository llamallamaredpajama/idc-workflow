#!/bin/bash
# idc-assert-class: behavior
# build-handle-backed-e2e.sh — F12: end-to-end coverage of the handle-backed validation path. A
# contract frozen via --handle-id resolves its verify commands from the governed verification-handle
# registry, and the handle metadata (handle_id + handle_registry) survives into the execution receipt
# AND the final Build receipt.
#
# Red-when-broken: drop handle_id from any of the three receipts and the matching assertion fires.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VC="$PLUGIN/scripts/idc_validation_contract.py"
BR="$PLUGIN/scripts/idc_build_receipt.py"
VH="$PLUGIN/scripts/idc_verification_handles.py"
CHECK="$PLUGIN/scripts/idc_review_verdict_check.py"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }
[ -f "$VC" ] || fail "missing build validation helper"
[ -f "$BR" ] || fail "missing build receipt helper"
[ -f "$VH" ] || fail "missing verification-handle helper"

GRAPH_DIGEST='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
PROJECTION_DIGEST='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
HANDLE="cli-smoke"

REPO="$WORK/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name tester
mkdir -p "$REPO/src/allowed" \
         "$REPO/docs/workflow" \
         "$REPO/docs/workflow/build-validation" \
         "$REPO/docs/workflow/build-validation-executions" \
         "$REPO/docs/workflow/build-receipts" \
         "$REPO/docs/workflow/code-reviews"
cat > "$REPO/verify.sh" <<'SH'
#!/bin/bash
set -euo pipefail
grep -qx 'new behavior' src/allowed/feature.txt
SH
chmod +x "$REPO/verify.sh"
printf 'old behavior\n' > "$REPO/src/allowed/feature.txt"

# The governed verification-handle registry: a cli handle whose verify command is the one the
# contract will run. --handle-id resolves the command from HERE, not from an explicit --verify.
cat > "$REPO/docs/workflow/verification-handles.yaml" <<'YAML'
schema_version: 1
handles:
  - handle_id: cli-smoke
    surface: cli
    evidence_kind: pane-capture
    build_commands: ["true"]
    launch_commands: ["true"]
    verify_commands: ["bash verify.sh"]
    fixtures: ["seed:none"]
    accounts: ["sandbox-user-placeholder"]
    emulators: ["none"]
YAML
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

python3 "$VH" validate --repo "$REPO" >/dev/null \
  || fail "the seeded verification-handle registry did not validate"

# (1) Freeze via --handle-id: verify commands come from the resolved handle; metadata is recorded.
CONTRACT="$REPO/docs/workflow/build-validation/handle.json"
python3 "$VC" freeze \
  --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --handle-id "$HANDLE" \
  --baseline expected-red --label handle-e2e --out "$CONTRACT" >/dev/null \
  || fail "could not freeze a handle-backed validation contract"
python3 - "$CONTRACT" "$HANDLE" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
handle = sys.argv[2]
if contract.get('handle_id') != handle:
    raise SystemExit(f"FAIL: frozen contract lost handle_id, got {contract.get('handle_id')!r}")
if contract.get('handle_registry') != 'docs/workflow/verification-handles.yaml':
    raise SystemExit(f"FAIL: frozen contract lost handle_registry, got {contract.get('handle_registry')!r}")
cmds = [row.get('command') for row in contract.get('verification') or []]
if cmds != ['bash verify.sh']:
    raise SystemExit(f"FAIL: contract did not resolve verify commands from the handle, got {cmds!r}")
print("ok: frozen contract resolved its verify command from the handle and recorded the handle metadata")
PY

# (2) Implement the behavior, run the resolved command, and prove the handle survives the execution.
printf 'new behavior\n' > "$REPO/src/allowed/feature.txt"
git -C "$REPO" add src/allowed/feature.txt
git -C "$REPO" commit -qm 'implement cli behavior'
EXEC="$REPO/docs/workflow/build-validation-executions/handle.json"
python3 "$VC" run --repo "$REPO" --contract "$CONTRACT" --out "$EXEC" >/dev/null \
  || fail "could not execute the handle-backed validation contract"
python3 - "$EXEC" "$HANDLE" <<'PY' || exit 1
import json, sys
execution = json.load(open(sys.argv[1], encoding='utf-8'))
handle = sys.argv[2]
if execution.get('handle_id') != handle:
    raise SystemExit(f"FAIL: execution receipt lost handle_id, got {execution.get('handle_id')!r}")
if execution.get('handle_registry') != 'docs/workflow/verification-handles.yaml':
    raise SystemExit(f"FAIL: execution receipt lost handle_registry, got {execution.get('handle_registry')!r}")
if execution.get('result') != 'pass':
    raise SystemExit(f"FAIL: handle-backed execution did not pass, got {execution.get('result')!r}")
print("ok: execution receipt carried the handle metadata and passed the resolved command")
PY

# (3) Write the Build receipt and prove the handle survives into it too.
VERDICT="$REPO/docs/workflow/code-reviews/2026-07-26-pr-401-handle.json"
python3 - "$EXEC" "$VERDICT" <<'PY'
import json, sys
exec_path, verdict_path = sys.argv[1:3]
receipt = json.load(open(exec_path, encoding='utf-8'))
verdict = {'verdict': 'PASS', 'issue': receipt['issue'], 'pr': receipt['pr'],
           'head': receipt['head'], 'diff_digest': receipt['diff_digest'], 'findings': []}
with open(verdict_path, 'w', encoding='utf-8') as fh:
    json.dump(verdict, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
python3 "$CHECK" "$VERDICT" >/dev/null 2>&1 \
  || fail "review verdict validator rejected the generated handle-backed verdict"
RECEIPT="$REPO/docs/workflow/build-receipts/handle.json"
python3 "$BR" write \
  --repo "$REPO" --contract "$CONTRACT" --execution "$EXEC" --verdict "$VERDICT" \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --out "$RECEIPT" >/dev/null \
  || fail "the handle-backed implementation receipt was rejected"
python3 - "$RECEIPT" "$HANDLE" <<'PY' || exit 1
import json, sys
receipt = json.load(open(sys.argv[1], encoding='utf-8'))
handle = sys.argv[2]
if receipt.get('handle_id') != handle:
    raise SystemExit(f"FAIL: Build receipt lost handle_id, got {receipt.get('handle_id')!r}")
print("ok: Build receipt carried the handle metadata through from the frozen contract")
PY

# (4) `--handle-id` WITH a disagreeing explicit `--verify` is refused, and the refusal names BOTH
# command lists. Nothing exercised this before: no test passed the two flags together, so the guard
# could be replaced with `if False:` and stay green. It is the guard that stops a builder from citing
# a governed recipe while silently running something else — the citation would then be decoration on
# a receipt that proves a different command ran.
mkdir -p "$REPO/other"
cat > "$REPO/other-verify.sh" <<'SH'
#!/bin/bash
true
SH
chmod +x "$REPO/other-verify.sh"
git -C "$REPO" add other-verify.sh
git -C "$REPO" commit -qm 'add a second gate script'
MISMATCH="$REPO/docs/workflow/build-validation/handle-mismatch.json"
out="$(python3 "$VC" freeze \
  --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --handle-id "$HANDLE" --verify 'bash other-verify.sh' \
  --baseline expected-green --label handle-mismatch --out "$MISMATCH" 2>&1)" \
  && fail "a contract citing $HANDLE while declaring a DIFFERENT explicit --verify command was accepted"
printf '%s\n' "$out" | grep -qF "bash verify.sh" \
  || fail "the handle/explicit-command mismatch refusal must name the RESOLVED command list; got: $out"
printf '%s\n' "$out" | grep -qF "bash other-verify.sh" \
  || fail "the handle/explicit-command mismatch refusal must name the EXPLICIT command list; got: $out"
[ ! -e "$MISMATCH" ] || fail "a refused handle/command mismatch still wrote a frozen contract at $MISMATCH"

# (5) POSITIVE TWIN — the identical command passed explicitly alongside `--handle-id` is ACCEPTED, so
# the refusal above is about DISAGREEMENT and not about passing both flags at all.
AGREE="$REPO/docs/workflow/build-validation/handle-agree.json"
python3 "$VC" freeze \
  --repo "$REPO" --issue 1 --pr 401 --graph-node alpha \
  --graph-digest "$GRAPH_DIGEST" --projection-digest "$PROJECTION_DIGEST" \
  --touch src/allowed/ --off-limits docs/ \
  --surface cli --handle-id "$HANDLE" --verify 'bash verify.sh' \
  --baseline expected-green --label handle-agree --out "$AGREE" >/dev/null \
  || fail "an explicit --verify that exactly matches the handle's verify_commands was wrongly refused"
python3 - "$AGREE" <<'PY' || exit 1
import json, sys
contract = json.load(open(sys.argv[1], encoding='utf-8'))
cmds = [row.get('command') for row in contract.get('verification') or []]
if cmds != ['bash verify.sh']:
    raise SystemExit(f"FAIL: the agreeing contract did not freeze the resolved command, got {cmds!r}")
print("ok: an explicit --verify identical to the handle's verify_commands is accepted")
PY

echo "PASS: a handle-backed contract resolves its verify command from the registry, the handle metadata survives into the execution receipt and the Build receipt, and a handle/explicit-command disagreement is refused by name"
