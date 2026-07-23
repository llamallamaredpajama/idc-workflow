#!/bin/bash
# interlock-project-mutation-verbs.sh — governance scenario: the mutation interlock denies EVERY
# board-mutating raw `gh project` verb, not just the subset the gate happened to list (spec §8 /
# threat T3 — raw GitHub bypass).
#
# The gap this pins (found by the final-gate hook-fidelity lane's synthetic-payload probe): the
# interlock denied `item-add|item-edit|item-delete|item-archive|field-create|create|edit|delete|
# copy|link|unlink` but ALLOWED four verbs that mutate the board just as hard —
#
#   * `item-create`   — mints a DRAFT board item outside the single write door;
#   * `field-delete`  — destroys a board field (the sibling of the already-denied `field-create`);
#   * `close`         — closes the whole project board;
#   * `mark-template` — flips the board into a template.
#
# What this scenario asserts:
#   * each of the four is a HARD DENY during an active `/idc:*` command, and the refusal names the
#     single write door (`idc_transition.py`) exactly as the already-denied verbs do;
#   * the deny survives gh flag placement and exec wrappers (same positional matcher);
#   * the whitespace backstop (used when a segment cannot be lexed) names the interlock's
#     single-write-door refusal for all four too — not a generic unparseable-command message;
#   * a read is NEVER newly denied — `item-list`, `view`, `field-list`, `list` (plain, wrapped, and
#     with a gh global flag) all stay ALLOWED. A false-deny of a read FAILS this scenario;
#   * every previously-denied `gh project` verb still denies (guards a botched refactor of the set);
#   * the four also deny OUTSIDE an active command (missing authorization is blocking, not warn-only);
#   * the sanctioned door (`idc_transition.py set-field`) is still never denied.
#
# Red-when-broken: drop any of the four verbs from the interlock's protected `gh project` set (or
# from its whitespace-backstop message path) → that verb is ALLOWED again → this scenario FAILs and
# names the still-allowed verb. Add a read verb to the protected set → the read control FAILs.
#
# Usage: bash tests/smoke/governance/interlock-project-mutation-verbs.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
DOOR="$GOV_PLUGIN/scripts/idc_transition.py"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT"
[ -f "$DOOR" ] || gov_fail "idc_transition.py (the single write door) not found at $DOOR"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
(
  cd "$REPO"
  git init -q
  git checkout -q -b main
)
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"

# S1 owns an ACTIVE /idc:think command; SNONE owns nothing (missing-authorization posture).
S1="s1-$$-$(basename "$WORK")"
SNONE="snone-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$S1" --command think \
  --plugin-root "$GOV_PLUGIN" --args 'project-verbs' --source user >/dev/null \
  || gov_fail "could not open the active /idc:think command record for $S1"

ERR="$WORK/err"
# emit a PreToolUse payload (cwd + tool + command + session) with python so command quoting is exact.
emit() { CWD="$1" TOOL="$2" CMD="$3" SID="$4" python3 -c \
  'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]},"session_id":os.environ["SID"]}))'; }
# gate <cmd> <session> → sets $OUT (stdout), $ERR file, $RC.
gate() { OUT="$(emit "$REPO" Bash "$1" "$2" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }
names_write_door() { printf '%s' "$OUT" | grep -qF "$DOOR"; }
is_board_mutation_refusal() { printf '%s' "$OUT" | grep -q 'board mutation'; }

# deny_verb <verb-label> <cmd> — must hard-deny under the ACTIVE session AND name the write door.
deny_verb() {
  gate "$2" "$S1"
  is_deny || gov_fail "raw \`gh project $1\` is a board mutation but the interlock ALLOWED it: [$2]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  names_write_door \
    || gov_fail "\`gh project $1\` denied WITHOUT naming the single write door ($DOOR): [$2] => [$OUT]"
  is_board_mutation_refusal \
    || gov_fail "\`gh project $1\` denied but not with the raw-board-mutation refusal message: [$2] => [$OUT]"
  echo "  ok deny (active command, names the write door): $2"
}
# deny_plain <cmd> — must hard-deny under the ACTIVE session (no message shape asserted).
deny_plain() {
  gate "$1" "$S1"
  is_deny || gov_fail "DENY expected (active command) but not denied: [$1]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  echo "  ok still denied: $1"
}
# allow_read <cmd> — a governed READ must NOT be denied or flagged. A false-deny of a read is a FAIL.
allow_read() {
  gate "$1" "$S1"
  is_deny && gov_fail "FALSE-DENY OF A READ: the interlock denied a governed \`gh project\` read: [$1] => [$OUT]"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0 but got $RC for a governed read: [$1]"
  [ -z "$OUT" ] || gov_fail "FALSE-DENY OF A READ: a governed read produced a permission decision: [$1] => [$OUT]"
  grep -q 'IDC interlock' "$ERR" && gov_fail "FALSE-FLAG OF A READ: [$1] => [$(cat "$ERR")]"
  echo "  ok allow (governed read, unflagged): $1"
}

echo "== the four board-mutating gh project verbs are HARD DENIED during an active command =="
deny_verb 'item-create'   'gh project item-create 5 --owner o --title draft'
deny_verb 'field-delete'  'gh project field-delete PVTSSF_1 --format json'
deny_verb 'close'         'gh project close 5 --owner o'
deny_verb 'mark-template' 'gh project mark-template 5 --owner o'

echo "== gh flag placement and exec wrappers cannot smuggle the four past the positional matcher =="
deny_verb 'item-create'   'gh -R o/r project item-create 5 --title draft'
deny_verb 'field-delete'  'gh project -R o/r field-delete PVTSSF_1'
deny_verb 'close'         'nohup gh project close 5 --owner o'
deny_verb 'mark-template' 'timeout 5 gh project mark-template 5 --owner o'
deny_verb 'item-create'   'gh --repo=o/r project item-create 5 --title draft'

echo "== the four are denied inside compounds and interpreter payloads too =="
deny_plain 'gh project view 5 --owner o && gh project close 5 --owner o'
deny_plain "bash -c 'gh project item-create 5 --owner o --title draft'"
deny_plain $'gh project view 5 --owner o\ngh project field-delete PVTSSF_1'

echo "== the whitespace BACKSTOP (unlexable segment) names the same single-write-door refusal =="
# A segment that cannot be lexed falls back to the whitespace matcher. Without the four verbs there,
# the refusal degrades to the generic "could not be parsed" Path Gate message and the interlock never
# names the raw board mutation. Red-when-broken: remove a verb from the backstop → the message for
# that verb loses the write-door remediation → this FAILs.
deny_verb 'item-create'   'gh project item-create 5 --owner o --title "draft'
deny_verb 'field-delete'  'gh project field-delete PVTSSF_1 --format "json'
deny_verb 'close'         'gh project close 5 --owner "o'
deny_verb 'mark-template' 'gh project mark-template 5 --owner "o'

echo "== NO read is newly denied — the governed gh project reads stay ALLOWED =="
allow_read 'gh project item-list 5 --owner o'
allow_read 'gh project view 5 --owner o'
allow_read 'gh project field-list 5 --owner o'
allow_read 'gh project list --owner o'
allow_read 'nohup gh project item-list 5 --owner o'
allow_read 'gh -R o/r project view 5'
allow_read 'gh project item-list 5 --owner o --format json --jq ".items[].title"'

echo "== every PREVIOUSLY-denied gh project verb still denies (no botched refactor of the set) =="
deny_plain 'gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O'
deny_plain 'gh project item-add --owner o --url https://github.com/o/r/issues/1'
deny_plain 'gh project item-delete 8 --owner o --id PVTI_X'
deny_plain 'gh project item-archive 8 --owner o --id PVTI_X'
deny_plain 'gh project field-create 5 --owner o --name Stage --data-type TEXT'
deny_plain 'gh project create --owner o --title x'
deny_plain 'gh project edit 5 --owner o --title y'
deny_plain 'gh project delete 8 --owner o'
deny_plain 'gh project copy 5 --source-owner o --target-owner p'
deny_plain 'gh project link 5 --owner o --repo o/r'
deny_plain 'gh project unlink 5 --owner o --repo o/r'

echo "== outside an active command the four still HARD DENY (missing authorization is blocking) =="
for c in 'gh project item-create 5 --owner o --title draft' \
         'gh project field-delete PVTSSF_1' \
         'gh project close 5 --owner o' \
         'gh project mark-template 5 --owner o'; do
  gate "$c" "$SNONE"
  [ "$RC" -eq 0 ] || gov_fail "(inactive) gate exit $RC, expected 0 (a hook signals via JSON, not exit code): [$c]"
  is_deny || gov_fail "(inactive) a non-active session did not deny the raw board mutation: [$c]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  echo "  ok deny (no live authorization): $c"
done

echo "== the sanctioned write door is still never denied =="
gate "python3 '$DOOR' --repo '$REPO' set-field --num 5 --field Wave --value W1" "$S1"
is_deny && gov_fail "the sanctioned single write door was DENIED: [$OUT]"
[ -z "$OUT" ] || gov_fail "the sanctioned single write door produced a permission decision: [$OUT]"
echo "  ok allow (sanctioned single write door)"

echo "PASS: the mutation interlock denies every board-mutating raw gh project verb — including item-create, field-delete, close, and mark-template — through the positional, wrapper, compound, and whitespace-backstop paths, always naming the single write door, while every governed gh project read stays allowed and every previously-denied verb still denies"
