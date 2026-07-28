#!/bin/bash
# idc-assert-class: behavior
# Phase 7 (update data-loss guard) smoke — audit F8.
#
# /idc:init writes real operator/board data into two scaffold files AFTER copying the template:
#   - WORKFLOW-config.yaml          (the derived `domains:` list)
#   - docs/workflow/tracker-config.yaml (project_number + board field_ids node IDs)
# If init stamps them `state: stamped`, /idc:update Phase 1 classifies them "unchanged +
# state: stamped" = pristine and Phase 2 silently overwrites them from the template, wiping the
# operator's domains / board wiring. The fix: init stamps them `state: customized`, which routes
# them to update's show-diff-and-ask instead.
#
# This test runs the REAL scaffold helper, simulates init's domain-write + the prescribed stamp,
# then faithfully replays update's silent-refresh rule and asserts the operator data survives.
# Hermetic: filesystem backend, no GitHub.
#
# Usage: bash tests/smoke/phase7-update-preserves-data.sh   (exit 0 = pass)
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$PLUGIN/scripts/idc_receipt_check.py"
SBX="$(mktemp -d)"
trap 'rm -rf "$SBX"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$HELPER" ] || fail "receipt helper not found at $HELPER"

# 1. Scaffold a filesystem repo with the real init scaffold helper.
bash "$PLUGIN/scripts/idc_init_scaffold.sh" "$PLUGIN" "$SBX" "TestProj" filesystem >/dev/null \
  || fail "scaffold helper exited non-zero"

CFG="$SBX/WORKFLOW-config.yaml"
RECEIPT="$SBX/docs/workflow/install-receipt.yaml"
SENTINEL="alpha-domain-sentinel"

# Simulate init Phase 3's agent step: write derived domains into $CFG, sourced from $1.
# (inline flow-list keeps the test sed portable across BSD/GNU — no newline in replacement)
inject_domains() {
  local tmp; tmp="$(mktemp)"
  sed "s|domains: \[\]|domains: [\"$SENTINEL\"]|" "$1" > "$tmp" && mv "$tmp" "$CFG"
  grep -q "$SENTINEL" "$CFG" || fail "could not inject operator domains from $1"
}

# 2. Inject the operator's domains into the scaffolded config.
grep -q 'domains: \[\]' "$CFG" || fail "template no longer has 'domains: []' to populate"
inject_domains "$CFG"

# 3. Stamp exactly as commands/init.md Phase 7 now prescribes: the two operator-data files
#    flagged --customized, the rest plain.
( cd "$SBX" && python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:init \
    --plugin-version 4.0.0 \
    --customized WORKFLOW-config.yaml --customized docs/workflow/tracker-config.yaml \
    WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/tracker-config.yaml docs/workflow/README.md \
    docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep ) \
  || fail "stamp exited non-zero"

# literal-substring lookups (no regex) for the receipt state + verify class of a path
state_of()    { awk -v p="path: $1" 'index($0,p){f=1} f&&/state:/{print $2; exit}' "$RECEIPT"; }
verify_class() { python3 "$HELPER" verify --repo "$SBX" 2>/dev/null | awk -v p="$1" '$2==p{print $1; exit}'; }
# update Phase 1 rule: a file is silently overwritten ONLY when unchanged AND state: stamped.
silently_refreshable() { [ "$(verify_class "$1")" = "unchanged" ] && [ "$(state_of "$1")" = "stamped" ]; }

# 4. The fix: both operator-data files are state: customized; ordinary template files are stamped.
[ "$(state_of WORKFLOW-config.yaml)" = "customized" ] \
  || fail "WORKFLOW-config.yaml must be state: customized (got '$(state_of WORKFLOW-config.yaml)')"
[ "$(state_of docs/workflow/tracker-config.yaml)" = "customized" ] \
  || fail "tracker-config.yaml must be state: customized (got '$(state_of docs/workflow/tracker-config.yaml)')"
[ "$(state_of WORKFLOW.md)" = "stamped" ] \
  || fail "WORKFLOW.md must stay state: stamped (got '$(state_of WORKFLOW.md)')"

# 5. Faithfully replay /idc:update Phase 2 (silent refresh of pristine files) and assert the
#    operator's domains survive — because the customized file is NOT silently-refreshable.
if silently_refreshable WORKFLOW-config.yaml; then
  cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$CFG"   # this would be the data loss
fi
grep -q "$SENTINEL" "$CFG" || fail "operator domains were wiped by a silent update refresh (F8)"
# control: a genuine pristine template file IS silently-refreshable (else the test proves nothing).
silently_refreshable WORKFLOW.md \
  || fail "a pristine template file (WORKFLOW.md) should be silently-refreshable (control)"

# 6. Negative control — without --customized the data loss returns, proving the flag is what
#    protects the file (guards against a silent revert of the init.md Phase 7 change).
inject_domains "$PLUGIN/templates/WORKFLOW-config.yaml"
( cd "$SBX" && python3 "$HELPER" stamp --repo "$SBX" --out "$RECEIPT" --written-by idc:init \
    --plugin-version 4.0.0 \
    WORKFLOW.md WORKFLOW-config.yaml \
    docs/workflow/tracker-config.yaml docs/workflow/README.md \
    docs/workflow/pillar-matrices/.gitkeep docs/workflow/code-reviews/.gitkeep ) \
  || fail "re-stamp (no --customized) exited non-zero"
silently_refreshable WORKFLOW-config.yaml \
  || fail "without --customized, WORKFLOW-config.yaml must be silently-refreshable (else the test can't catch the bug)"
cp "$PLUGIN/templates/WORKFLOW-config.yaml" "$CFG"   # update would overwrite it...
grep -q "$SENTINEL" "$CFG" && fail "negative control: domains should have been wiped without --customized"

# ── 7. The verification-handle registry is operator data too ─────────────────────────────────────
# `docs/workflow/verification-handles.yaml` holds the operator's proven drive recipes. /idc:update
# documents a preserve-and-validate branch for it, and NO phase7 test mentioned the registry at all —
# so the branch could be deleted, or quietly turned into a template overwrite, with every update test
# still green. This replays that branch exactly as commands/update.md prescribes it, in both
# directions, and asserts the shipped playbook still carries the rule being replayed.
UPDATE_MD="$PLUGIN/commands/update.md"
VH="$PLUGIN/scripts/idc_verification_handles.py"
REG="$SBX/docs/workflow/verification-handles.yaml"
TEMPLATE_REG="$PLUGIN/templates/docs-tree/verification-handles.yaml"
[ -f "$UPDATE_MD" ] || fail "commands/update.md not found at $UPDATE_MD"
[ -f "$VH" ] || fail "verification-handle helper not found at $VH"
[ -f "$REG" ] || fail "the scaffold no longer lays down docs/workflow/verification-handles.yaml"

# The shipped rule itself: preserve on a clean validate, report-and-stop (never overwrite) otherwise.
python3 - "$UPDATE_MD" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
if 'docs/workflow/verification-handles.yaml' not in text:
    raise SystemExit("FAIL: commands/update.md no longer names the verification-handle registry")
if not re.search(r'idc_verification_handles\.py"?\s+validate', text):
    raise SystemExit(
        "FAIL: commands/update.md no longer validates the registry through the fixed helper before "
        "preserving it")
m = re.search(r'idc_verification_handles\.py"?\s+validate', text)
window = text[max(0, m.start() - 800):m.start() + 1500]
if 'preserved' not in window:
    raise SystemExit("FAIL: commands/update.md no longer reports the registry as `preserved`")
if 'Never overwrite the registry' not in window:
    raise SystemExit(
        "FAIL: commands/update.md no longer forbids overwriting a failing registry with the template "
        "— that prohibition is the whole guard")
print("ok: /idc:update still documents preserve-and-validate for the verification-handle registry")
PY

# The operator's own recipe, in the file /idc:init scaffolded.
python3 "$VH" append --repo "$SBX" --handle-id operator-recipe --surface cli \
  --verify-command 'bash scripts/drive-the-app.sh' --fixture 'seed:operator' >/dev/null \
  || fail "could not seed an operator recipe into the scaffolded registry"
OP_COPY="$SBX/registry.operator.bak"
cp "$REG" "$OP_COPY"

# 7a. Clean registry → update's branch validates, reports `preserved`, and leaves the bytes alone.
python3 "$VH" validate --repo "$SBX" >/dev/null \
  || fail "an operator registry with one appended recipe failed the update preserve-path validation"
cmp -s "$REG" "$OP_COPY" \
  || fail "the read-only preserve-path validation modified the operator's registry"
grep -qF 'operator-recipe' "$REG" \
  || fail "the operator's recipe did not survive the update preserve path"
cmp -s "$REG" "$TEMPLATE_REG" \
  && fail "the operator's registry is byte-identical to the template — the fixture proves nothing"

# 7b. Malformed registry → the helper errors, update reports it and STOPS. Replaying the branch means
#     the template must NOT be copied over the operator's file to make the warning go away.
cat > "$REG" <<'YAML'
schema_version: 1
handles:
  - handle_id: operator-recipe
    surface: cli
    evidence_kind: response-body
    build_commands: []
    launch_commands: []
    verify_commands: ["bash scripts/drive-the-app.sh"]
    fixtures: ["seed:operator"]
    accounts: []
    emulators: []
YAML
cp "$REG" "$SBX/registry.malformed.bak"
set +e
vh_out="$(python3 "$VH" validate --repo "$SBX" 2>&1)"
vh_rc=$?
set -e
[ "$vh_rc" -ne 0 ] || fail "a registry whose evidence_kind contradicts its surface passed validation"
printf '%s\n' "$vh_out" | grep -qi 'evidence_kind' \
  || fail "the malformed-registry error must name the offending field so update can report it verbatim; got: $vh_out"
# The branch under test: on failure update reports and stops — it does not refresh from the template.
if [ "$vh_rc" -eq 0 ]; then
  cp "$TEMPLATE_REG" "$REG"            # only reachable if validation passed — i.e. never, here
fi
cmp -s "$REG" "$SBX/registry.malformed.bak" \
  || fail "update overwrote a failing operator registry instead of reporting the helper error and stopping"
grep -qF 'operator-recipe' "$REG" \
  || fail "the operator's recipe was wiped by the malformed-registry path (F8 class, registry edition)"

echo "PASS: init stamps operator-data files customized → /idc:update can't silently wipe domains/field_ids, and the verification-handle registry is preserved on both the clean and the malformed path"
