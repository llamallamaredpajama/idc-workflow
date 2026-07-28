#!/bin/bash
# idc-assert-class: behavior
# doctor-handle-citation-audit.sh — /idc:doctor Row 9's dangling verification-handle citation check.
#
# Row 9 is documented as "advisory; never FAIL". The check that backs it had three defects, all
# invisible to the six existing doctor tests:
#   1. The invocation lived in Row 9's PROSE, not in a runnable ```bash fence like every other
#      executable step in that row — deleting it left lint and all six doctor tests green, so the
#      check shipped unwired.
#   2. `audit-citations` raised an unhandled FileNotFoundError (exit 1) when
#      `docs/workflow/build-validation/` was absent. `idc_init_scaffold.sh` never creates that
#      directory — it is minted by the first frozen contract — so EVERY freshly initialized repo hit
#      a traceback. A traceback is neither a warning nor a SKIP.
#   3. A missing registry `die()`d at exit 2, which on a pre-registry repo turns an advisory row into
#      a hard doctor failure.
#
# Proves: the invocation is fenced; both absent inputs produce an exit-0 SKIP with no traceback; a
# genuine dangling citation still WARNs and still exits 0.
set -uo pipefail
PLUGIN="$(cd "$(dirname "$0")/../../.." && pwd)"
VH="$PLUGIN/scripts/idc_verification_handles.py"
DOCTOR="$PLUGIN/commands/doctor.md"
SCAFFOLD="$PLUGIN/scripts/idc_init_scaffold.sh"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$VH" ] || fail "missing verification-handle helper at $VH"
[ -f "$DOCTOR" ] || fail "commands/doctor.md not found at $DOCTOR"

# (A) The invocation is inside a runnable ```bash fence in doctor.md — not stranded in prose.
python3 - "$DOCTOR" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], encoding='utf-8').read()
fences = re.findall(r"```bash\n(.*?)```", text, re.S)
hits = [f for f in fences if 'idc_verification_handles.py' in f and 'audit-citations' in f]
if not hits:
    raise SystemExit(
        "FAIL: commands/doctor.md never runs `idc_verification_handles.py audit-citations` from a "
        "```bash fence — a step that only exists in prose is a step that never runs")
if not any('--contracts-dir' in f for f in hits):
    raise SystemExit(
        f"FAIL: the fenced audit-citations invocation does not pass --contracts-dir, so it audits no "
        f"frozen contracts at all: {hits!r}")
print("ok: doctor.md Row 9 runs the citation audit from a fenced block")
PY
grep -qF 'SKIP' "$DOCTOR" \
  || fail "commands/doctor.md must document the SKIP outcome for the citation audit"

# (B) A REAL freshly-scaffolded repo — the exact state /idc:init leaves behind — audits cleanly.
#     `docs/workflow/build-validation/` does not exist there, which used to be an unhandled traceback.
SBX="$WORK/fresh"
mkdir -p "$SBX"
( cd "$SBX" && git init -q )
bash "$SCAFFOLD" "$PLUGIN" "$SBX" "Doctor Test" filesystem >/dev/null \
  || fail "scaffold helper failed while creating the doctor-audit fixture"
[ -d "$SBX/docs/workflow/build-validation" ] \
  && fail "this fixture assumes init does NOT scaffold docs/workflow/build-validation/ — it now does, so case (B) no longer covers the fresh-repo state"
set +e
out="$(python3 "$VH" audit-citations --repo "$SBX" --contracts-dir "$SBX/docs/workflow/build-validation" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a freshly-initialized repo (no docs/workflow/build-validation/) must audit at exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -qF 'SKIP:' \
  || fail "an absent frozen-contract directory must produce an explicit SKIP line; got: $out"
printf '%s\n' "$out" | grep -qiE 'Traceback|FileNotFoundError' \
  && fail "the citation audit raised a traceback on a freshly-initialized repo: $out"

# (C) A repo with NO registry at all (every pre-registry install) — SKIP, exit 0, never a die().
BARE="$WORK/bare"
mkdir -p "$BARE/docs/workflow/build-validation"
( cd "$BARE" && git init -q )
set +e
out="$(python3 "$VH" audit-citations --repo "$BARE" --contracts-dir "$BARE/docs/workflow/build-validation" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a repo with no verification-handle registry must audit at exit 0, got $rc: $out"
printf '%s\n' "$out" | grep -qF 'SKIP:' \
  || fail "an absent registry must produce an explicit SKIP line, not a die(); got: $out"
printf '%s\n' "$out" | grep -qi 'registry' \
  || fail "the absent-registry SKIP must say WHAT is missing; got: $out"

# (D) A genuine dangling citation still WARNs — and still exits 0 (advisory; never a hard FAIL).
LIVE="$WORK/live"
mkdir -p "$LIVE/docs/workflow/build-validation"
( cd "$LIVE" && git init -q )
cat > "$LIVE/docs/workflow/verification-handles.yaml" <<'YAML'
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
# The dangling id is deliberately unlike any path or scaffolding token in this fixture, so the
# assertion below cannot be satisfied by the fixture's own filenames.
printf '{"handle_id":"retired-recipe-xyz"}\n' > "$LIVE/docs/workflow/build-validation/frozen.json"
printf '{"handle_id":"cli-smoke"}\n' > "$LIVE/docs/workflow/build-validation/frozen-ok.json"
set +e
out="$(python3 "$VH" audit-citations --repo "$LIVE" --contracts-dir "$LIVE/docs/workflow/build-validation" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "a dangling handle citation must stay ADVISORY (exit 0), got $rc: $out"
printf '%s\n' "$out" | grep -qF 'cites unknown handle_id' \
  || fail "a dangling citation must print the 'cites unknown handle_id' warning; got: $out"
printf '%s\n' "$out" | grep -qF "retired-recipe-xyz" \
  || fail "the warning must name the dangling id; got: $out"
printf '%s\n' "$out" | grep -qF "'cli-smoke'" \
  && fail "the audit warned about a handle that DOES exist in the registry: $out"

echo "PASS: doctor's handle-citation audit is fenced and runnable, SKIPs (exit 0, no traceback) on an absent registry or contracts dir, and warns without failing on a dangling citation"
