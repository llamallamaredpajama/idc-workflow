#!/usr/bin/env bash
# phase13-ask-entry-gate.sh — `/idc:ask` routes safely through the admission gate.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GATE="$REPO_ROOT/scripts/hooks/idc_command_entry_gate.py"
CONTRACT="$REPO_ROOT/scripts/idc_command_contract.py"
PATH_GATE="$REPO_ROOT/scripts/idc_path_gate.py"
fail() { echo "FAIL: $*" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"
mkdir -p "$REPO/docs/workflow"
git -C "$REPO" init -q
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
VERSION="$(python3 - "$REPO_ROOT/.claude-plugin/plugin.json" <<'PY'
import json, sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["version"])
PY
)"
printf 'receipt_version: 2\nplugin_version: %s\n' "$VERSION" > "$REPO/docs/workflow/install-receipt.yaml"

emit_ask() {
  SID="$1" TEXT="$2" REPO="$REPO" python3 - <<'PY'
import json, os
text = os.environ["TEXT"]
print(json.dumps({
    "session_id": os.environ["SID"], "cwd": os.environ["REPO"],
    "hook_event_name": "UserPromptExpansion", "expansion_type": "command",
    "command_name": "idc:ask", "command_args": text, "command_source": "plugin",
    "prompt": "/idc:ask" + (" " + text if text else ""),
}))
PY
}

active_record() {
  python3 "$CONTRACT" status --repo "$REPO" --session "$1" --json | python3 -c '
import json, sys
command = sys.argv[1]
doc = json.load(sys.stdin)
matches = [r for r in doc["active"] if r.get("command") == command]
assert len(matches) == 1, doc
print(json.dumps(matches[0], sort_keys=True))
' "$2"
}

# 1. A confident request retargets to pause and records that ask was its source.
OUT="$(emit_ask ask-route 'stop work here' | python3 "$GATE" "$REPO_ROOT")"
printf '%s' "$OUT" | grep -q '/idc:pause' || fail "confident ask did not inject pause context"
printf '%s' "$OUT" | grep -q 'You reached this command through /idc:ask' \
  || fail "confident ask did not inject the mandatory confirmation preamble"
RECORD="$(active_record ask-route pause)" || fail "confident ask did not open a pause record"
printf '%s' "$RECORD" | grep -q '"source": "ask"' \
  || fail "retargeted pause record did not record ask as its source"
python3 "$CONTRACT" status --repo "$REPO" --session ask-route --json | grep -q '"command": "ask"' \
  && fail "confident ask opened an ask record instead of pause"

# 2. Ambiguous language stays advisory: it opens ask and has no Path Gate authorization.
AUTH="$(python3 "$PATH_GATE" auth-path --repo "$REPO")"
rm -f "$AUTH"
OUT="$(emit_ask ask-ambiguous 'stop and then pick up later' | python3 "$GATE" "$REPO_ROOT")"
printf '%s' "$OUT" | grep -q 'advisory' || fail "ambiguous ask did not inject advisory context"
active_record ask-ambiguous ask >/dev/null || fail "ambiguous ask did not open an ask record"
[ ! -e "$AUTH" ] || fail "ambiguous ask unexpectedly wrote a Path Gate authorization"

# 3. Installation lifecycle requests stay advisory and never open an uninstall record.
OUT="$(emit_ask ask-lifecycle 'uninstall idc' | python3 "$GATE" "$REPO_ROOT")"
printf '%s' "$OUT" | grep -q 'lifecycle-command' \
  || fail "lifecycle ask did not explain its deliberate refusal"
active_record ask-lifecycle ask >/dev/null || fail "lifecycle ask did not open an ask record"
python3 "$CONTRACT" status --repo "$REPO" --session ask-lifecycle --json | grep -q '"command": "uninstall"' \
  && fail "lifecycle ask opened an uninstall record"

echo "PASS: phase13-ask-entry-gate"
