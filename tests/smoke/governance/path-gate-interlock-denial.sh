#!/bin/bash
# path-gate-interlock-denial.sh — the shared Path Gate reaches Claude's PreToolUse transport:
# direct Write/Edit file mutations deny without a live authorization; generic Bash file writers,
# file utilities, command substitutions, script indirection, BASH_ENV startup files, and the supported
# `apply_patch` Bash alias are stopped before execution; a sanctioned command session can still write
# ordinary source files; protected machine-owned tracker files stay denied; and raw gh tracker writes
# stay denied whether or not a lifecycle record exists.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

ENTRY="$GOV_PLUGIN/scripts/hooks/idc_command_entry_gate.py"
GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$ENTRY" ] || gov_fail "idc_command_entry_gate.py not found at $ENTRY"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
printf 'export const seed = 3;\n' > "$REPO/src/seed.ts"
PLUGIN_VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$GOV_PLUGIN/.claude-plugin/plugin.json")"
printf 'receipt_version: 2\nplugin_version: %s\n' "$PLUGIN_VERSION" > "$REPO/docs/workflow/install-receipt.yaml"

SID_NONE="pg-none-$$-$(basename "$WORK")"
SID_BUILD="pg-build-$$-$(basename "$WORK")"
ERR="$WORK/err"

emit_tool() { # emit_tool <tool> <value> <session>
  TOOL="$1" VALUE="$2" SID="$3" REPO="$REPO" python3 - <<'PY'
import json, os
payload = {
    "cwd": os.environ["REPO"],
    "tool_name": os.environ["TOOL"],
    "session_id": os.environ["SID"],
}
tool = os.environ["TOOL"]
value = os.environ["VALUE"]
if tool == "Bash":
    payload["tool_input"] = {"command": value}
elif tool == "Write":
    payload["tool_input"] = {"file_path": value, "content": "x"}
else:
    payload["tool_input"] = {"file_path": value}
print(json.dumps(payload))
PY
}

gate() { OUT="$(emit_tool "$1" "$2" "$3" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }
is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }
allow_case() {
  gate "$1" "$2" "$3"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0 but got $RC for $1:$2"
  [ -z "$OUT" ] || gov_fail "ALLOW expected no permission decision for $1:$2, got: $OUT"
  grep -q 'IDC interlock' "$ERR" && gov_fail "ALLOW unexpectedly warned for $1:$2 ⇒ $(cat "$ERR")"
}
deny_case() {
  gate "$1" "$2" "$3"
  [ "$RC" -eq 0 ] || gov_fail "DENY expected exit 0 but got $RC for $1:$2 ⇒ $(cat "$ERR")"
  is_deny || gov_fail "DENY expected permissionDecision=deny for $1:$2, stdout=[$OUT] stderr=[$(cat "$ERR")]"
}

authorize_build() {
  ENTRY_OUT="$(python3 - "$REPO" <<'PY' | python3 "$ENTRY" "$GOV_PLUGIN"
import json, os, sys
repo = sys.argv[1]
print(json.dumps({
    "session_id": os.environ["SID_BUILD"],
    "cwd": repo,
    "hook_event_name": "UserPromptExpansion",
    "expansion_type": "command",
    "command_name": "idc:build",
    "command_args": "ticket demo",
    "command_source": "plugin",
    "prompt": "/idc:build ticket demo",
}))
PY
)"
  printf '%s' "$ENTRY_OUT" | grep -q 'additionalContext' \
    || gov_fail "entry gate did not admit /idc:build with additionalContext: $ENTRY_OUT"
  python3 "$CONTRACT" status --repo "$REPO" --session "$SID_BUILD" --json | grep -q '"command": "build"' \
    || gov_fail "entry gate did not register the active build command"
}
export SID_BUILD

RAW_TRACKER_REDIRECT="printf 'ticket: raw\\n' > TRACKER.md"
RAW_TRACKER_PY="python3 -c \"open('TRACKER.md','w').write('ticket: raw\\n')\""
RAW_TRACKER_CP="cp src/seed.ts TRACKER.md"
RAW_TRACKER_MV="mv src/seed.ts TRACKER.md"
RAW_TRACKER_BASH_C="bash -c 'cp src/seed.ts TRACKER.md'"
RAW_TRACKER_BASH_DYNAMIC='CMD="cp src/seed.ts TRACKER.md"; bash -c "$CMD"'
RAW_TRACKER_SH_C="sh -c 'mv src/seed.ts TRACKER.md'"
RAW_TRACKER_ZSH_C="zsh -c 'printf \"ticket: zsh\\n\" > TRACKER.md'"
RAW_TRACKER_ENV_S="env -S 'bash -c \"cp src/seed.ts TRACKER.md\"'"
RAW_TRACKER_ENV_S_DYNAMIC='CMD="bash -c \"cp src/seed.ts TRACKER.md\""; env -S "$CMD"'
RAW_TRACKER_SUBST=': $(cp src/seed.ts TRACKER.md)'
RAW_TRACKER_CD_CHAIN="cd src && cp seed.ts ../TRACKER.md"
RAW_SRC_PY="python3 -c \"open('src/x.ts','w').write('export const x = 2;\\n')\""
RAW_SRC_CP="cp src/seed.ts src/copied.ts"
RAW_SRC_MV="mv src/seed.ts src/moved.ts"
RAW_SRC_BASH_C="bash -c 'cp src/seed.ts src/copied.ts'"
RAW_SRC_ENV_S="env -S 'bash -c \"cp src/seed.ts src/copied.ts\"'"
RAW_SRC_CD_CHAIN="cd src && cp seed.ts copied.ts"
WRITER_SCRIPT="$WORK/write-tracker.sh"
cat > "$WRITER_SCRIPT" <<'SH'
cp src/seed.ts TRACKER.md
SH
SAFE_WRITER_SCRIPT="$WORK/write-src.sh"
cat > "$SAFE_WRITER_SCRIPT" <<'SH'
cp src/seed.ts src/copied.ts
SH
RAW_TRACKER_SCRIPT="bash '$WRITER_SCRIPT'"
RAW_TRACKER_SOURCE="source '$WRITER_SCRIPT'"
RAW_TRACKER_BASH_ENV="BASH_ENV='$WRITER_SCRIPT' bash -c 'echo hi'"
RAW_TRACKER_BASH_ENV_NESTED="BASH_ENV='$WRITER_SCRIPT' env -S 'bash -c \"echo hi\"'"
RAW_SRC_SCRIPT="bash '$SAFE_WRITER_SCRIPT'"
PATCH_TRACKER="$(cat <<'PATCH'
apply_patch <<'EOF'
*** Begin Patch
*** Update File: TRACKER.md
@@
-ticket: demo
+ticket: patched
*** End Patch
EOF
PATCH
)"
PATCH_SRC="$(cat <<'PATCH'
apply_patch <<'EOF'
*** Begin Patch
*** Update File: src/x.ts
@@
-export const x = 1;
+export const x = 2;
*** End Patch
EOF
PATCH
)"

# No live authorization: every repository-writing surface must deny.
deny_case Bash "$RAW_TRACKER_REDIRECT" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_PY" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_CP" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_MV" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_BASH_C" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_BASH_DYNAMIC" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_SH_C" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_ZSH_C" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_ENV_S" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_ENV_S_DYNAMIC" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_SUBST" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_CD_CHAIN" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_SCRIPT" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_SOURCE" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_BASH_ENV" "$SID_NONE"
deny_case Bash "$RAW_TRACKER_BASH_ENV_NESTED" "$SID_NONE"
deny_case Bash "$PATCH_TRACKER" "$SID_NONE"
deny_case Write "$REPO/TRACKER.md" "$SID_NONE"
deny_case Edit "$REPO/src/x.ts" "$SID_NONE"
deny_case Bash 'gh issue create --title gate --body-file /tmp/body' "$SID_NONE"

authorize_build
allow_case Bash "$RAW_SRC_PY" "$SID_BUILD"
allow_case Bash "$RAW_SRC_CP" "$SID_BUILD"
allow_case Bash "$RAW_SRC_MV" "$SID_BUILD"
allow_case Bash "$RAW_SRC_BASH_C" "$SID_BUILD"
allow_case Bash "$RAW_SRC_ENV_S" "$SID_BUILD"
allow_case Bash "$RAW_SRC_CD_CHAIN" "$SID_BUILD"
allow_case Bash "$RAW_SRC_SCRIPT" "$SID_BUILD"
allow_case Bash "$PATCH_SRC" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_REDIRECT" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_PY" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_CP" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_MV" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_BASH_C" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_BASH_DYNAMIC" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_SH_C" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_ZSH_C" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_ENV_S" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_ENV_S_DYNAMIC" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_SUBST" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_CD_CHAIN" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_SCRIPT" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_SOURCE" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_BASH_ENV" "$SID_BUILD"
deny_case Bash "$RAW_TRACKER_BASH_ENV_NESTED" "$SID_BUILD"
deny_case Bash "$PATCH_TRACKER" "$SID_BUILD"
allow_case Write "$REPO/src/x.ts" "$SID_BUILD"
deny_case Write "$REPO/TRACKER.md" "$SID_BUILD"
deny_case Bash 'gh issue create --title gate --body-file /tmp/body' "$SID_BUILD"

echo "PASS: the shared Path Gate denies unauthenticated Write/Edit/raw-gh mutations, recursively blocks cp/mv/redirection/apply_patch through bash/sh/zsh/env -S/script/BASH_ENV/command-substitution forms, still admits authorized ordinary source writes, and keeps protected tracker/raw-gh writes blocked"
