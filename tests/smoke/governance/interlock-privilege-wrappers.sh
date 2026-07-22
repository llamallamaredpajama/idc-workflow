#!/bin/bash
# interlock-privilege-wrappers.sh — sudo/doas/su cannot hide the incident interpreter FILE/payload,
# and the wrapped raw write must still HARD DENY even with no active lifecycle record.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
FIXTURE="$GOV_PLUGIN/tests/smoke/fixtures/session-b7a93ff6/fire_gate.sh"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE"
[ -f "$FIXTURE" ] || gov_fail "incident fixture fire_gate.sh missing at $FIXTURE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
SID="priv-none-$$-$(basename "$WORK")"
ERR="$WORK/err"

emit() { CWD="$REPO" TOOL="Bash" CMD="$1" SID="$SID" python3 -c \
  'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]},"session_id":os.environ["SID"]}))'; }

gate() { OUT="$(emit "$1" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }
is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }

commands=(
  "sudo bash '$FIXTURE'"
  "sudo -u root sh '$FIXTURE'"
  "doas zsh '$FIXTURE'"
  "doas -u root bash '$FIXTURE'"
  "su -c \"bash '$FIXTURE'\" root"
  "su root -c \"sh '$FIXTURE'\""
  'su --command="gh issue create --title gate --body-file /tmp/body" root'
)

for command in "${commands[@]}"; do
  gate "$command"
  [ "$RC" -eq 0 ] || gov_fail "privilege-wrapper gate exit was $RC, expected 0 for: $command"
  is_deny || gov_fail "privilege wrapper bypassed hard denial outside a live authorization: [$command] stdout=[$OUT] stderr=[$(cat "$ERR")]"
  printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -q 'fire_gate.sh' \
    && printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -qv 'reached indirectly' \
    && gov_fail "privilege-wrapper denial leaked the incident fixture path without the indirectness note: [$command]"
  echo "  ok privilege wrapper denied: $command"
done

echo "PASS: sudo/doas/su interpreter-file and payload forms are still hard-denied with no active lifecycle record"
