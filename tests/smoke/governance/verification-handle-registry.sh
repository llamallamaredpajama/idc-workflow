#!/bin/bash
# verification-handle-registry.sh — U6 verification-handle registry + secret-free fixed validators.
# Proves:
#   (a) the registry schema validates and a matching handle resolves through fixed code;
#   (b) malformed, schema-version-mismatched, unknown-field, or invalid-shape entries are refused;
#   (c) secret-bearing / credential-bearing fields are rejected before citation or use;
#   (d) a missing handle returns a NAMED recirculation / blocked-dependency obligation, never a warning-only pass;
#   (e) doctor's read-only citation audit warns on nonexistent handle ids;
#   (f) the scaffolded registry is receipt-listed and preserved as operator data (`always_ask`).
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
SCHEMA="$PLUGIN/scripts/idc_schema_check.py"
VH="$PLUGIN/scripts/idc_verification_handles.py"
RCHK="$PLUGIN/scripts/idc_receipt_check.py"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
INIT_MD="$PLUGIN/commands/init.md"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCHEMA" ] || fail "missing schema checker: verification-handle registry validation is still absent"
[ -f "$VH" ] || fail "missing verification-handle helper: fixed registry resolution is still absent"
[ -f "$SCAFFOLD" ] || fail "scaffold helper not found at $SCAFFOLD"

REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
REG="$REPO/docs/workflow/verification-handles.yaml"
cat > "$REG" <<'YAML'
schema_version: 1
handles:
  - handle_id: api-health
    surface: api
    evidence_kind: response-body
    build_commands: ["npm run build"]
    launch_commands: ["npm start"]
    verify_commands: ["curl -s http://localhost:3000/health"]
    fixtures: ["seed:smoke"]
    accounts: ["sandbox-user-placeholder"]
    emulators: ["none"]
YAML

python3 "$SCHEMA" registry "$REG" >/dev/null \
  || fail "a valid verification-handle registry was rejected by the fixed schema checker"
python3 "$VH" validate --repo "$REPO" --registry "$REG" >/dev/null \
  || fail "a valid verification-handle registry was rejected by the fixed resolver"
out="$(python3 "$VH" resolve --repo "$REPO" --registry "$REG" --handle-id api-health --surface api)" \
  || fail "a valid verification handle did not resolve"
python3 -c 'import json,sys
obj=json.load(sys.stdin)
handle=obj.get("handle") or {}
assert handle.get("handle_id")=="api-health", f"FAIL: resolved handle_id mismatch: {handle}"
assert handle.get("surface")=="api" and handle.get("evidence_kind")=="response-body", f"FAIL: resolved handle lost the fixed surface/evidence pairing: {handle}"
assert handle.get("verify_commands")==["curl -s http://localhost:3000/health"], f"FAIL: resolved handle lost its verify command: {handle}"
print("ok: valid verification handle resolved through fixed code")' <<<"$out" || exit 1

# (B1) schema-version mismatch is refused.
BAD_VERSION="$WORK/bad-version.yaml"
cat > "$BAD_VERSION" <<'YAML'
schema_version: 9
handles: []
YAML
out="$(python3 "$SCHEMA" registry "$BAD_VERSION" 2>&1)" \
  && fail "a schema-version-mismatched registry was accepted"
printf '%s\n' "$out" | grep -qi 'schema_version' \
  || fail "schema-version refusal must name the mismatch; got: $out"

# (B2) unknown fields are refused.
BAD_FIELD="$WORK/bad-field.yaml"
cat > "$BAD_FIELD" <<'YAML'
schema_version: 1
handles:
  - handle_id: api-health
    surface: api
    evidence_kind: response-body
    build_commands: ["npm run build"]
    launch_commands: ["npm start"]
    verify_commands: ["curl -s http://localhost:3000/health"]
    fixtures: ["seed:smoke"]
    accounts: ["sandbox-user-placeholder"]
    emulators: ["none"]
    unknown_field: boom
YAML
out="$(python3 "$SCHEMA" registry "$BAD_FIELD" 2>&1)" \
  && fail "a registry entry with an unknown field was accepted"
printf '%s\n' "$out" | grep -qiE 'unknown_field|unknown field' \
  || fail "unknown-field refusal must name the unexpected key; got: $out"

# (B3) invalid recipe shape is refused.
BAD_SHAPE="$WORK/bad-shape.yaml"
cat > "$BAD_SHAPE" <<'YAML'
schema_version: 1
handles:
  - handle_id: api-health
    surface: api
    evidence_kind: response-body
    build_commands: ["npm run build"]
    launch_commands: ["npm start"]
    verify_commands: "curl -s http://localhost:3000/health"
    fixtures: ["seed:smoke"]
    accounts: ["sandbox-user-placeholder"]
    emulators: ["none"]
YAML
out="$(python3 "$SCHEMA" registry "$BAD_SHAPE" 2>&1)" \
  && fail "an invalid registry recipe shape was accepted"
printf '%s\n' "$out" | grep -qiE 'verify_commands|list|shape' \
  || fail "invalid-shape refusal must explain the list requirement; got: $out"

# (C) secret-bearing / credential-bearing fields are rejected before citation or use.
BAD_SECRET="$WORK/bad-secret.yaml"
cat > "$BAD_SECRET" <<'YAML'
schema_version: 1
handles:
  - handle_id: api-health
    surface: api
    evidence_kind: response-body
    build_commands: ["npm run build"]
    launch_commands: ["npm start"]
    verify_commands: ["curl -H 'Authorization: Bearer ghp_012345678901234567890123456789012345' http://localhost:3000/health"]
    fixtures: ["seed:smoke"]
    accounts: ["sandbox-user-placeholder"]
    emulators: ["none"]
YAML
out="$(python3 "$VH" validate --repo "$REPO" --registry "$BAD_SECRET" 2>&1)" \
  && fail "synthetic credential-bearing registry material was accepted"
printf '%s\n' "$out" | grep -qiE 'secret|credential|bearer|token|auth' \
  || fail "secret-free refusal must explain the credential-bearing field; got: $out"

# (D) missing handle => named obligation, never warning-only.
set +e
out="$(python3 "$VH" resolve --repo "$REPO" --registry "$REG" --handle-id missing-api --surface api --missing-action recirculation --obligation-name missing-api-handle 2>/dev/null)"
rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a missing verification handle resolved without creating an obligation"
python3 -c 'import json,sys
obj=json.load(sys.stdin)
obligation=obj.get("obligation") or {}
assert obligation.get("kind")=="recirculation", f"FAIL: missing handle did not return a recirculation obligation: {obligation}"
assert obligation.get("name")=="missing-api-handle", f"FAIL: missing handle obligation lost its required name: {obligation}"
assert obligation.get("handle_id")=="missing-api", f"FAIL: missing handle obligation lost the cited handle id: {obligation}"
print("ok: missing verification handle returned a named obligation")' <<<"$out" || exit 1

# (E) doctor's read-only audit warns on nonexistent citations.
CONTRACT="$WORK/contract.json"
cat > "$CONTRACT" <<'JSON'
{"handle_id":"missing-api"}
JSON
out="$(python3 "$VH" audit-citations --repo "$REPO" --registry "$REG" --contract "$CONTRACT")" \
  || fail "doctor-style citation audit must stay warning-only on a nonexistent handle"
printf '%s\n' "$out" | grep -qiE 'warning:.*missing-api|unknown handle' \
  || fail "doctor-style citation audit did not warn on the nonexistent handle citation: $out"

# (F) scaffold + receipt integration: the registry is copied, stamped, and preserved as operator data.
SBX="$WORK/scaffold"
mkdir -p "$SBX"
( cd "$SBX" && git init -q )
bash "$SCAFFOLD" "$PLUGIN" "$SBX" "Handle Test" filesystem >/dev/null \
  || fail "scaffold helper failed while creating the verification-handle registry"
[ -f "$SBX/docs/workflow/verification-handles.yaml" ] \
  || fail "verification-handle registry not scaffolded into docs/workflow/"
python3 "$SCHEMA" registry "$SBX/docs/workflow/verification-handles.yaml" >/dev/null \
  || fail "the scaffolded verification-handle registry template failed its own schema check"
STAMP_PATHS="$(python3 - "$INIT_MD" <<'PY'
import re, shlex, sys
text = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'idc_receipt_check\.py"?\s+stamp\b(.*?)```', text, re.S)
if not m:
    sys.exit('could not find the idc_receipt_check.py stamp block in commands/init.md')
body = m.group(1).replace("\\\n", " ")
toks = shlex.split(body, comments=True)
VALUED = {"--repo", "--out", "--plugin-version", "--written-by", "--customized"}
paths, i = [], 0
while i < len(toks):
    tok = toks[i]
    if tok in VALUED:
        i += 2
        continue
    if tok.startswith('--'):
        i += 1
        continue
    paths.append(tok)
    i += 1
print('\n'.join(paths))
PY
)" || fail "could not parse commands/init.md's Phase 7 stamp list"
echo "$STAMP_PATHS" | grep -qxF 'docs/workflow/verification-handles.yaml' \
  || fail "commands/init.md Phase 7 stamp list omits docs/workflow/verification-handles.yaml"
echo "$STAMP_PATHS" | xargs python3 "$RCHK" stamp \
  --repo "$SBX" \
  --out "$SBX/docs/workflow/install-receipt.yaml" \
  --plugin-version 9.9.9 \
  --written-by idc:init \
  --customized WORKFLOW-config.yaml \
  --customized docs/workflow/tracker-config.yaml >/dev/null \
  || fail "stamping the scaffolded verification-handle registry failed"
vout="$(python3 "$RCHK" verify --repo "$SBX" --json)" || fail "receipt verification failed on the scaffolded registry"
python3 -c 'import json,sys
obj=json.load(sys.stdin)
always_ask=set(obj.get("always_ask") or [])
assert "docs/workflow/verification-handles.yaml" in always_ask, f"FAIL: verification-handles.yaml must be preserved as operator data (always_ask), got {sorted(always_ask)}"
unrecorded=obj.get("unrecorded") or []
assert not unrecorded, f"FAIL: fresh scaffold left governed files unrecorded: {unrecorded}"
print("ok: scaffolded verification-handle registry is receipt-listed and preserved as operator data")' <<<"$vout" || exit 1

# (G) PLAN'S LOOKUP STEP IS A SHIPPED INVARIANT, not decoration. `handle_id` is OPTIONAL in fixed
# code — by design, since a first-of-its-kind surface has no entry to cite — so a Plan that quietly
# stopped citing handles would emit contracts that pass every validator while the registry decayed
# into a write-only file. Nothing asserted the playbook still tells Plan to look one up: deleting all
# five registry/resolver lines from agents/idc-plan.md + commands/plan.md left lint and twelve
# plan-touching tests green. These are prose invariants over the SHIPPED playbooks, scoped to the
# phase that owns each step so a mention drifting into an unrelated section does not satisfy them.
PLAN_AGENT="$PLUGIN/agents/idc-plan.md"
PLAN_CMD="$PLUGIN/commands/plan.md"
[ -f "$PLAN_AGENT" ] || fail "agents/idc-plan.md not found at $PLAN_AGENT"
[ -f "$PLAN_CMD" ] || fail "commands/plan.md not found at $PLAN_CMD"

phase_slice() {  # $1 = file, $2 = heading prefix — the text of that phase section only
  python3 - "$1" "$2" <<'PY'
import re, sys
path, heading = sys.argv[1:3]
text = open(path, encoding='utf-8').read()
m = re.search(rf"^##\s+{re.escape(heading)}.*?$(.*?)(?=^##\s|\Z)", text, re.M | re.S)
if not m:
    sys.exit(f"could not find a '## {heading}' section in {path}")
print(m.group(1))
PY
}

P3="$(phase_slice "$PLAN_AGENT" 'Phase 3')" || fail "$P3"
printf '%s\n' "$P3" | grep -qF 'idc_verification_handles.py' \
  || fail "agents/idc-plan.md Phase 3 no longer routes contract authoring through idc_verification_handles.py — the registry lookup is gone and Plan re-derives every recipe"
printf '%s\n' "$P3" | grep -qE 'idc_verification_handles\.py"? resolve' \
  || fail "agents/idc-plan.md Phase 3 must name the fixed RESOLVER (`idc_verification_handles.py resolve ...`), not merely mention the registry"
printf '%s\n' "$P3" | grep -qiE 'recirculation|blocked-dependency' \
  || fail "agents/idc-plan.md Phase 3 must route a MISSING handle into a named recirculation / blocked-dependency obligation — without it a miss silently weakens the gate"

P5="$(phase_slice "$PLAN_AGENT" 'Phase 5')" || fail "$P5"
printf '%s\n' "$P5" | grep -qE 'idc_schema_check\.py"? registry' \
  || fail "agents/idc-plan.md Phase 5 must schema-check the governed registry (`idc_schema_check.py registry ...`) before any cited handle_id is used"

grep -qF 'docs/workflow/verification-handles.yaml' "$PLAN_CMD" \
  || fail "commands/plan.md no longer names the governed registry path docs/workflow/verification-handles.yaml"
grep -qF 'idc_verification_handles.py' "$PLAN_CMD" \
  || fail "commands/plan.md no longer names the fixed verification-handle helper"

echo "ok: Plan's registry lookup + miss-routing + schema-check steps are still in the shipped playbooks"

echo "PASS: verification handles are schema-checked, secret-free, obligation-backed on misses, doctor-warned on nonexistent citations, cited by Plan's shipped playbook, and scaffolded as preserved operator data"