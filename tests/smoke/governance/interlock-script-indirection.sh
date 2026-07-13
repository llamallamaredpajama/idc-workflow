#!/bin/bash
# interlock-script-indirection.sh — governance scenario: the mutation interlock is HARD during an
# active IDC command AND sees THROUGH shell indirection (Task 3, command integrity).
#
# The session-b7a93ff6 incident: an agent mid-`/idc:think` hid a raw `gh issue create` gate firing
# inside a throwaway `fire_gate.sh` and ran `bash fire_gate.sh`, so the command-string interlock of
# the day saw only `bash fire_gate.sh` and waved it through. This scenario pins the fix:
#
#   * while a session owns an ACTIVE `/idc:*` command, a raw protected mutation is a HARD DENY
#     (permissionDecision=deny), not a warning — the posture change from opt-in to active-command deny;
#   * the interlock inspects interpreter indirection: `bash|sh|zsh FILE`, `source FILE`, `. FILE`,
#     and quoted `bash -c '…'` payloads are resolved and their protected operations matched;
#   * the newly-protected raw ops (`gh issue create`, a `dependencies/blocked_by` REST write) deny;
#   * the SAME raw command OUTSIDE an active command stays a warning (ordinary governed-repo work is
#     never bricked), and IDC_HOOKS_OBSERVE_ONLY=1 downgrades the active-session deny to a warning;
#   * an unreadable / over-64-KiB / sensitive interpreter target is denied as opaque WITHOUT ever
#     opening it (no secret content is echoed into a denial);
#   * the sanctioned door (`idc_transition.py`, `idc_pr_finish.py`) is never denied.
#
# Red-when-broken: revert the interlock to warn-only / drop inspect_command → every `deny` case below
# stops denying → this scenario FAILs.
#
# Usage: bash tests/smoke/governance/interlock-script-indirection.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
FIXTURE="$GOV_PLUGIN/tests/smoke/fixtures/session-b7a93ff6"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$FIXTURE/fire_gate.sh" ] || gov_fail "incident fixture fire_gate.sh missing at $FIXTURE"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"

# S1 owns an ACTIVE /idc:think command (the incident's live command); SNONE owns nothing.
S1="s1-$$-$(basename "$WORK")"
SNONE="snone-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$S1" --command think \
  --plugin-root "$GOV_PLUGIN" --args 'incident' --source user >/dev/null \
  || gov_fail "could not open the active /idc:think command record for $S1"

ERR="$WORK/err"
# emit a PreToolUse payload (cwd + tool + command + session) with python so command quoting is exact.
emit() { CWD="$1" TOOL="$2" CMD="$3" SID="$4" python3 -c \
  'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]},"session_id":os.environ["SID"]}))'; }
# gate <cmd> <session> [env-prefixes handled by caller] → sets $OUT (stdout), $ERR file, $RC.
gate() { OUT="$(emit "$REPO" Bash "$1" "$2" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }

# deny <cmd> — under the ACTIVE session S1, the command must be a hard deny.
deny() {
  gate "$1" "$S1"
  is_deny || gov_fail "DENY expected (active command) but not denied: [$1]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  echo "  ok deny (active command): $1"
}
# allow <cmd> — under the ACTIVE session S1, a sanctioned command must NOT be denied or flagged.
allow() {
  gate "$1" "$S1"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0 but got $RC: [$1]"
  [ -z "$OUT" ] || gov_fail "ALLOW expected no permission decision but got one: [$1] => [$OUT]"
  grep -q 'IDC interlock' "$ERR" && gov_fail "ALLOW wrongly flagged the sanctioned command: [$1] => [$(cat "$ERR")]"
  echo "  ok allow (sanctioned, active command): $1"
}

echo "== the incident + newly-protected raw ops are HARD DENIED during an active command =="
deny 'gh issue create --title gate --body-file /tmp/body'
deny "bash '$FIXTURE/fire_gate.sh'"
deny "sh '$FIXTURE/fire_gate.sh'"
deny "zsh '$FIXTURE/fire_gate.sh'"
deny "source '$FIXTURE/fire_gate.sh'"
deny ". '$FIXTURE/fire_gate.sh'"
deny "bash -c 'gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O'"
deny "gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE"

echo "== the sanctioned write door is never denied =="
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' create-ticket --title safe --stage Buildable --status Todo"
allow "python3 '$GOV_PLUGIN/scripts/idc_pr_finish.py' autonomous --repo '$REPO' --pr 12 --kind planning"

echo "== outside an active command, the same raw mutation stays a WARNING (never bricks ordinary work) =="
gate 'gh issue create --title gate --body-file /tmp/body' "$SNONE"
[ "$RC" -eq 0 ] || gov_fail "(warn) gate exit $RC, expected 0 (warn never blocks)"
[ -z "$OUT" ] || gov_fail "(warn) a non-active session must NOT emit a permission decision: $OUT"
grep -q 'IDC interlock' "$ERR" || gov_fail "(warn) non-active session lost the interlock warning: $(cat "$ERR")"
echo "  ok non-active session ⇒ warn (no deny)"

echo "== IDC_HOOKS_OBSERVE_ONLY=1 downgrades the active-session deny to a warning =="
OUT="$(emit "$REPO" Bash 'gh issue create --title gate --body-file /tmp/body' "$S1" | IDC_HOOKS_OBSERVE_ONLY=1 python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?
[ -z "$OUT" ] || gov_fail "(observe) OBSERVE_ONLY must downgrade the deny → no stdout decision: $OUT"
grep -qi 'would deny' "$ERR" || gov_fail "(observe) OBSERVE_ONLY did not warn-downgrade the deny: $(cat "$ERR")"
echo "  ok OBSERVE_ONLY downgrades the active-session deny to a warning"

echo "== an opaque interpreter target (oversize / unreadable) is denied as opaque-script-indirection, unopened =="
BIG="$WORK/big.sh"; head -c 70000 /dev/zero | tr '\0' '#' > "$BIG"; printf '\ngh issue create x\n' >> "$BIG"
deny "bash '$BIG'"
printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -q 'opaque-script-indirection' \
  || gov_fail "(oversize) deny reason must name opaque-script-indirection: [$OUT][$(cat "$ERR")]"
UNREAD="$WORK/unread.sh"; printf 'gh issue create x\n' > "$UNREAD"; chmod 000 "$UNREAD"
deny "bash '$UNREAD'"
printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -q 'opaque-script-indirection' \
  || gov_fail "(unreadable) deny reason must name opaque-script-indirection: [$OUT][$(cat "$ERR")]"
chmod 644 "$UNREAD"
echo "  ok oversize + unreadable interpreter targets ⇒ opaque-script-indirection deny"

echo "== sensitive interpreter targets are denied WITHOUT ever being opened (no content echoed) =="
SENTINEL='SENTINEL_LEAK_9c2f_MUST_NOT_APPEAR'
for name in .env .envrc key.pem id_rsa my_credential_file my_secret_file; do
  f="$WORK/$name"; printf 'export TOKEN=%s\n' "$SENTINEL" > "$f"
  gate "source '$f'" "$S1"
  is_deny || gov_fail "(sensitive) source of $name during an active command must be denied: [$OUT][$(cat "$ERR")]"
  if printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -q "$SENTINEL"; then
    gov_fail "(sensitive) the interlock ECHOED $name's content into the denial — it must never open a sensitive file"
  fi
done
echo "  ok .env/.envrc/*.pem/id_rsa*/credential/secret targets ⇒ denied unread, no content leaked"

echo "PASS: the mutation interlock is a hard deny during an active IDC command, sees through bash/sh/zsh/source/. indirection and quoted bash -c payloads, protects gh issue create + dependency REST writes, downgrades under OBSERVE_ONLY, warns (never bricks) outside an active command, and refuses opaque/sensitive interpreter targets unread"
