#!/bin/bash
# path-gate-interlock-denial.sh — the shared Path Gate reaches Claude's PreToolUse transport:
# direct Write/Edit file mutations deny without a live authorization, a sanctioned command session can
# write inside its allowed source surface, protected machine-owned tracker files stay denied, and raw
# gh tracker writes stay denied whether or not a lifecycle record exists.
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
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const x = 1;\n' > "$REPO/src/x.ts"
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

# No live authorization: direct file-authoring surfaces must deny.
gate Write "$REPO/TRACKER.md" "$SID_NONE"
is_deny || gov_fail "raw Write to TRACKER.md without authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
gate Edit "$REPO/src/x.ts" "$SID_NONE"
is_deny || gov_fail "raw Edit to src/x.ts without authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
gate Bash 'gh issue create --title gate --body-file /tmp/body' "$SID_NONE"
is_deny || gov_fail "raw gh issue create without authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"

authorize_build
allow_case Write "$REPO/src/x.ts" "$SID_BUILD"
gate Write "$REPO/TRACKER.md" "$SID_BUILD"
is_deny || gov_fail "authorized build session still allowed a direct TRACKER.md write: stdout=[$OUT] stderr=[$(cat "$ERR")]"
gate Bash 'gh issue create --title gate --body-file /tmp/body' "$SID_BUILD"
is_deny || gov_fail "authorized build session still allowed a raw gh issue create: stdout=[$OUT] stderr=[$(cat "$ERR")]"

echo "PASS: the shared Path Gate denies unauthenticated Write/Edit/raw-gh mutations, admits authorized source writes, and still blocks protected tracker/raw-gh writes"
