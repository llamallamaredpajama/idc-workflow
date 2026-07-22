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
#   * the SAME raw command OUTSIDE an active command is still a hard deny — missing authorization is
#     not a warn-only posture anymore — and IDC_HOOKS_OBSERVE_ONLY=1 downgrades any deny to a warning;
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
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow" "$REPO/src"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'ticket: demo\n' > "$REPO/TRACKER.md"
printf 'export const payload = 3;\n' > "$REPO/src/payload.ts"
WRITER="$WORK/write-tracker.sh"
cat > "$WRITER" <<'SH'
cp src/payload.ts TRACKER.md
SH

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

echo "== a shell-prefix cannot smuggle the incident script past interpreter inspection =="
deny "X=1 bash '$FIXTURE/fire_gate.sh'"
deny "env X=1 bash '$FIXTURE/fire_gate.sh'"
deny "env A=1 B=2 command bash '$FIXTURE/fire_gate.sh'"
deny "command bash '$FIXTURE/fire_gate.sh'"
deny "builtin source '$FIXTURE/fire_gate.sh'"
deny "exec bash '$FIXTURE/fire_gate.sh'"

echo "== wrapper OPTIONS cannot hide the interpreter — env/command options are skipped (round-3 Fix 4) =="
deny "env -i bash '$FIXTURE/fire_gate.sh'"
deny "env -u X bash '$FIXTURE/fire_gate.sh'"
deny "env -i -u FOO bash '$FIXTURE/fire_gate.sh'"
deny "env -C /tmp bash '$FIXTURE/fire_gate.sh'"
deny "env -u X A=1 bash '$FIXTURE/fire_gate.sh'"
deny "command -p bash '$FIXTURE/fire_gate.sh'"
deny "command -pv bash '$FIXTURE/fire_gate.sh'"

echo "== gh GLOBAL FLAGS before the subcommand cannot bypass the deny (round-3 Fix 3 normalize) =="
deny 'gh -R o/r issue create --title gate --body-file /tmp/body'
deny 'gh --repo o/r pr merge 12 --squash'
deny 'gh --repo=o/r issue close 5'
deny 'gh -R o/r project item-delete 8 --id X'
echo "== gh api METHOD forms (combined / =-joined) + combined -F body flag deny (round-3 Fix 3) =="
deny 'gh api --method=DELETE repos/o/r/issues/707/dependencies/blocked_by/708'
deny 'gh api -XDELETE repos/o/r/issues/707/dependencies/blocked_by/708'
deny 'gh api --method=POST repos/o/r/issues/707/dependencies/blocked_by -Fissue_id=8'
deny 'gh api -XPOST repos/o/r/issues/707/dependencies/blocked_by -fissue_id=8'
echo "== the reopenIssue GraphQL mutation is in the protected write family (round-3 Fix 3) =="
deny "gh api graphql -f query='mutation{reopenIssue(input:{issueId:\"I_1\"}){issue{id}}}'"

echo "== round-4 Fix 1: gh flags BETWEEN subcommand levels + the \`issue new\` alias cannot bypass =="
deny 'gh issue -R o/r create --title gate --body-file /tmp/body'
deny 'gh pr --repo o/r merge 12 --squash'
deny 'gh issue -R o/r close 5'
deny 'gh project -R o/r item-delete 8 --id X'
deny 'gh issue new --title gate --body-file /tmp/body'
echo "== round-4 Fix 1: the -X=DELETE method form denies a dependency write =="
deny 'gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X=DELETE'
echo "== round-4 Fix 1: the GraphQL write-mutation FAMILY (verb+object) is caught, not a fixed list =="
deny "gh api graphql -f query='mutation{createProjectV2(input:{ownerId:\"O\"}){projectV2{id}}}'"
deny "gh api graphql -f query='mutation{copyProjectV2(input:{}){projectV2{id}}}'"
deny "gh api graphql -f query='mutation{linkProjectV2ToRepository(input:{}){repository{id}}}'"
echo "== round-4 Fix 1: env -S \"<string>\" is parsed recursively (like bash -c) =="
deny "env -S \"bash '$FIXTURE/fire_gate.sh'\""
deny "env -S 'gh issue create --title x --body-file /tmp/b'"
echo "== round-4 Fix 1: an AMBIGUOUS gh api method on a protected path fails closed (active command) =="
deny 'gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X "$METHOD"'

echo "== the direct classifier's REST/GraphQL write set denies (segment-based fail-closed posture) =="
deny 'gh api repos/o/r/issues/5 -X PATCH -f state=open'
deny 'gh api repos/o/r/issues/5 -X PATCH -f state=CLOSED'
deny "gh api graphql -f query='mutation{updateIssue(input:{id:\"I_1\",state:CLOSED}){issue{id}}}'"
deny "gh api graphql -f query='mutation{clearProjectV2ItemFieldValue(input:{}){projectV2Item{id}}}'"
deny "gh api graphql -f query='mutation{archiveProjectV2Item(input:{}){item{id}}}'"
deny 'gh api --method POST repos/o/r/issues/707/dependencies/blocked_by -f issue_id=708'

echo "== the classifier is METHOD-AWARE — a read-only dependency GET (doctor's audit) is ALLOWED (Fix 4) =="
allow "gh api repos/o/r/issues/707/dependencies/blocked_by --paginate --jq '.[].number'"

echo "== protected words used as literal inspection/documentation data are not executable mutations =="
allow "grep -F 'gh issue create' '$GOV_PLUGIN/skills/idc-tracker-github/SKILL.md'"
allow "echo 'gh issue create --title documented-example'"
allow "printf '%s\\n' 'gh project item-edit --id documented-example'"

echo "== round-5 Fix 1: per-SEGMENT classification + fail-closed gh api — every round-4 bypass denies =="
# gh GLOBAL flag (--hostname) between `gh` and `api` no longer breaks `gh api` detection.
deny 'gh --hostname github.com api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE'
# The `: -X GET && …` decoy: method detection is PER SEGMENT, so the leading `-X GET` cannot mask the
# real `-X DELETE` in the second segment (each segment is judged on its own tokens).
deny ': -X GET && gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE'
# `env -S "<string>"` reconstructs the FULL split-string INCLUDING trailing args → `gh issue create …`.
deny "env -S 'gh issue' create --title x"
# Redirected script stdin: `bash < FILE` resolves FILE and inspects it like `bash FILE`.
deny "bash < '$FIXTURE/fire_gate.sh'"
# A `gh api graphql` with an opaque `--input FILE` body cannot be proven a pure read → fail-closed DENY.
deny 'gh api graphql --input mutation.json'

echo "== round-5 Fix 1: read-only forms stay ALLOWED (the fail-closed posture never over-blocks reads) =="
allow "gh issue view 5"
allow "gh pr view 12"
allow "gh --hostname github.com api repos/o/r/issues/707/dependencies/blocked_by/708"
allow "gh api repos/o/r/issues"

echo "== round-6 Fix 1+2: blunt newline-aware segment classifier + fail-closed gh api =="
# (1) LAST -X wins in real gh, so a leading `-X GET` decoy cannot mask a real write — scan ALL methods.
deny 'gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X GET -X DELETE'
# (2) a value-taking-flag mis-parse (`-p nebula`) no longer isolates a wrong endpoint — the write
#     indicator (-X DELETE) + protected path anywhere in the segment is enough to DENY.
deny 'gh api -p nebula repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE'
# (3) NEWLINE-separated commands are separate segments (shlex silently eats newlines; raw-split first).
deny $': -X GET\ngh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE'
deny $'gh issue view 5\ngh issue -R o/r create --title x'
# (4) the read-only dependency GET the doctor audit runs stays ALLOWED (never over-blocked).
allow "gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X GET"

echo "== round-7 Fix 1: a read-only gh api graphql QUERY is ALLOWED; a graphql mutation/opaque body DENIES =="
# Doctor's board-link probe and Update's Stage-field read are LITERAL query{…} reads — they must be
# ALLOWED even during an active command (both commands hold active lifecycle records). Red-when-broken:
# drop _graphql_is_read → the blunt "any -f body flag = write" rule denies these read queries again.
allow "gh api graphql -f query='query(\$o:String!,\$r:String!){repository(owner:\$o,name:\$r){projectsV2(first:100){nodes{number}}}}' -f o=x -f r=y --jq .data"
allow "gh api graphql -f query='query(\$p:ID!){node(id:\$p){... on ProjectV2{field(name:\"Stage\"){... on ProjectV2SingleSelectField{id options{id name color description}}}}}}' -f p=PVT_1 --jq .data.node.field"
# A real GraphQL mutation still DENIES — decided on the OPERATION (mutation keyword), not the body flag.
deny "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}}}'"
# Fail-closed: an OPAQUE query body (a shell variable / command substitution) carries no literal
# selection set we can prove is a read, so it DENIES — a mutation cannot be smuggled through `\$MUT`.
deny 'gh api graphql -f query="$MUT"'

echo "== round-7 Fix 2: a backslash-newline continuation is joined BEFORE segmenting (no bypass) =="
# Bash runs `gh \`+newline+`issue create` as `gh issue create`, but the old segmenter split on the raw
# newline into harmless pieces. Collapse line-continuations first → the joined `gh issue create` DENIES
# during an active command. Red-when-broken: drop the continuation collapse → this segments away → allow.
deny $'gh \\\nissue create --title x --body-file /tmp/b'
deny $'gh issue view 5 && gh \\\nissue create --title x --body-file /tmp/b'

echo "== round-8 Fix 1: only the graphql QUERY arg is parsed — a --jq brace decoy cannot mask an opaque mutation =="
# The whole-command "any word 'query' + any '{'" heuristic let a --jq '{...}' brace make an opaque
# `-f query=\"\$MUT\"` mutation look readable. Parse the query ARG value specifically: an opaque
# (shell-expansion) query body DENIES regardless of an unrelated brace elsewhere; a literal read query
# stays ALLOWED even with a --jq object. Red-when-broken: revert to the whole-command scan → the decoy
# masks the mutation → the deny stops firing.
deny "MUT='mutation{x}'; gh api graphql -f query=\"\$MUT\" --jq '{data:.data}'"
allow "gh api graphql -f query='query{viewer{login}}' --jq '{x:.x}'"

echo "== round-8 Fix 2: a DYNAMIC bash -c / env -S payload fails closed; a static payload is inspected =="
# `bash -c \"\$CMD\"` used to recurse on the literal token \$CMD, find nothing, and ALLOW — while the
# shell expands it to a real mutation. A payload carrying ANY shell expansion now DENIES as
# opaque-shell-indirection; a fully static payload is still inspected recursively (a real mutation in it
# denies, a benign command allows). Red-when-broken: drop the expansion guard → the dynamic payload
# recurses on \$CMD, finds nothing, and the deny stops firing.
deny "CMD=\"gh issue \"\"create --title x --body-file /tmp/b\"; bash -c \"\$CMD\""
deny "bash -c 'gh issue create --title x --body-file /tmp/b'"
deny "env -S \"\$CMD\""
allow "bash -c 'echo hi'"

echo "== the shared Path Gate recurses through shell payloads, scripts, and startup files for generic writers too =="
deny "bash '$WRITER'"
deny "sh '$WRITER'"
deny "zsh '$WRITER'"
deny "source '$WRITER'"
deny ". '$WRITER'"
deny "bash -c 'cp src/payload.ts TRACKER.md'"
deny "sh -c 'mv src/payload.ts TRACKER.md'"
deny "zsh -c 'printf \"ticket: nested\\n\" > TRACKER.md'"
deny "env -S 'bash -c \"cp src/payload.ts TRACKER.md\"'"
deny "BASH_ENV='$WRITER' bash -c 'echo hi'"
deny "BASH_ENV='$WRITER' env -S 'bash -c \"echo hi\"'"
deny 'echo $(cp src/payload.ts TRACKER.md)'
allow "bash -c 'echo hi'"

echo "== round-9 Fix A: unresolvable DYNAMIC constructs fail closed BY CONSTRUCTION (findings 1/3/4 + class) =="
# finding 1 — a `gh api` whose ENDPOINT is a shell expansion (`$EP` could be `graphql` / a protected REST
# path) carrying a write indicator cannot be statically confirmed safe → DENY during an active command.
# Red-when-broken: drop the dynamic-endpoint guard → the endpoint isn't a literal `graphql`, so the blunt
# path classifier sees no protected path and waves the mutation through.
deny "EP=graphql; gh api \"\$EP\" -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}}'"
# finding 4 — a BASH_ENV/ENV/*RC prefix assignment points a NON-interactive interpreter at a file it
# sources BEFORE running its `-c` payload, so a static-looking `bash -c 'echo hi'` can smuggle a mutation
# through the sourced startup file → DENY (both the bare-prefix and the `env`-wrapped forms).
deny "BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
deny "ENV='$FIXTURE/fire_gate.sh' sh -c 'echo hi'"
deny "env BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
# a DYNAMIC-endpoint gh api READ (no write indicator) stays ALLOWED (never over-blocks reads).
allow "gh api \"\$EP\" --jq .foo"

echo "== raw lifecycle writes are DENIED during an ACTIVE uninstall =="
# Uninstall performs its opt-in teardown through idc_gh_board.py. Raw issue/project writes have no
# command-name exception: their target cannot be trusted merely because `uninstall` is active.
SUN="sun-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SUN" --command uninstall \
  --plugin-root "$GOV_PLUGIN" --args 'teardown' --source user >/dev/null \
  || gov_fail "could not open the active /idc:uninstall command record for $SUN"

allow_under() {  # allow_under <session> <cmd> — sanctioned adapter call must NOT deny or warn.
  gate "$2" "$1"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0 but got $RC: [$2]"
  [ -z "$OUT" ] || gov_fail "ALLOW expected no permission decision but got one: [$2] => [$OUT]"
  grep -q 'IDC interlock' "$ERR" && gov_fail "ALLOW wrongly flagged sanctioned adapter call: [$2] => [$(cat "$ERR")]"
  echo "  ok allow (sanctioned adapter): $2"
}
deny_under() {  # deny_under <session> <cmd> — must hard-deny under that session.
  gate "$2" "$1"
  is_deny || gov_fail "DENY expected under session but not denied: [$2]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  echo "  ok deny: $2"
}

# Even uninstall's intended raw teardown forms are denied.
deny_under "$SUN" "gh issue close 5"
deny_under "$SUN" "gh project delete 8 --owner o"
deny_under "$SUN" "gh project item-delete 8 --owner o --id PVTI_X"
# The same forms remain denied under every other active command.
deny_under "$S1" "gh issue close 5"
deny_under "$S1" "gh project delete 8 --owner o"
# Other protected writes stay denied too.
deny_under "$SUN" "gh issue create --title x --body-file /tmp/b"
deny_under "$SUN" "gh pr merge 12 --squash"
deny_under "$SUN" "gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE"
deny_under "$SUN" "gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O"
# Compounds and indirection remain denied in full.
deny_under "$SUN" "gh issue close 5 && gh issue create --title x --body-file /tmp/b"
deny_under "$SUN" "gh issue close 5 && gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE"
deny_under "$SUN" "bash -c 'gh issue close 5; gh api graphql --input mutation.json'"
# A `gh \`+newline+`issue create` is joined before classification and denied.
deny_under "$SUN" $'gh issue close 5 && gh \\\nissue create --title x --body-file /tmp/b'
# A compound containing only intended teardown writes is still raw and denied.
deny_under "$SUN" "gh issue close 5 && gh project item-delete 8 --owner o --id PVTI_X"
# Command substitutions do not weaken the raw-write denial.
deny_under "$SUN" "gh issue close 5 --comment \"\$(gh issue create --title x --body x)\""
deny_under "$SUN" "gh issue close 5 --comment \"\`gh issue create --title x --body x\`\""

echo "== raw lifecycle writes are DENIED during an ACTIVE init =="
# Init provisions through idc_gh_board.py. Raw create/field/link/GraphQL writes have no active-command
# exception and therefore cannot target an unrelated board under cover of Init.
SIN="sin-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SIN" --command init \
  --plugin-root "$GOV_PLUGIN" --args 'provision' --source user >/dev/null \
  || gov_fail "could not open the active /idc:init command record for $SIN"

# Even Init's intended raw provisioning forms are denied.
deny_under "$SIN" 'gh project create --owner o --title "x IDC Tracker" --format json'
deny_under "$SIN" 'gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options "Consideration,Planning,Buildable,Recirculation"'
deny_under "$SIN" 'gh project link 5 --owner o --repo o/r'
deny_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\",singleSelectOptions:[{name:\"Todo\",color:GRAY}]}){projectV2Field{id}}}'"
# The same forms remain denied under every other active command.
deny_under "$S1" 'gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options "Consideration"'
deny_under "$S1" 'gh project link 5 --owner o --repo o/r'
deny_under "$S1" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}}}'"
# Every other protected mutation stays denied during Init.
deny_under "$SIN" 'gh issue create --title x --body-file /tmp/b'
deny_under "$SIN" 'gh pr merge 12 --squash'
deny_under "$SIN" 'gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O'
deny_under "$SIN" 'gh project delete 8 --owner o'
deny_under "$SIN" "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",state:CLOSED}){issue{id}}}'"

echo "== dynamic constructs beside raw provisioning writes remain DENIED under init =="
deny_under "$SIN" "gh project link 5 --owner o --repo \"\$(gh issue create --title x --body x)\""
deny_under "$SIN" "gh project link 5 --owner o --repo <(gh issue create --title x)"

echo "== GraphQL provisioning-shaped mutations receive no Init exception =="
# Both a foreign root and a genuine project-field root are raw writes and denied.
deny_under "$SIN" "gh api graphql -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}} # updateProjectV2Field'"
deny_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}}}'"

echo "== substitutions do not hide a raw lifecycle write =="
deny_under "$SIN" "existing=\$(gh project field-list 5 --owner o --format json --jq '.fields[].name'); gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options X"
deny_under "$SIN" "linked=\$(gh api graphql -f query='query(\$o:String!,\$r:String!){repository(owner:\$o,name:\$r){projectsV2(first:100){nodes{number}}}}' -f o=o -f r=r --jq .data); gh project link 5 --owner o --repo o/r"
# A benign inner read cannot make the raw outer close legal.
deny_under "$SUN" "gh issue close 5 --comment \"\$(gh issue view 6 --json title --jq .title)\""
# A write inner also denies.
deny_under "$SIN" "gh project field-create 5 --owner o --name S --data-type SINGLE_SELECT --single-select-options \"\$(gh issue create --title x --body x)\""
deny_under "$SUN" "gh issue close 5 --comment \"\`gh issue create --title x --body x\`\""

echo "== init's ACTUAL sanctioned provisioning fences pass under active init =="
# Extract the shipped idc_gh_board lifecycle calls, not synthetic commands. They are allowed because
# the helper validates scope and performs the GitHub subprocess behind the adapter door.
INITMD="$GOV_PLUGIN/commands/init.md"
[ -f "$INITMD" ] || gov_fail "commands/init.md not found at $INITMD"
# Bash 3.2-compatible (macOS /bin/bash is 3.2.57, no `mapfile`): read one JSON-line
# fence per iteration. The python emits one `json.dumps(body)` line per fence (never a
# bare empty line), so a plain read loop preserves the exact set mapfile would have built.
FENCES=()
while IFS= read -r line; do FENCES+=("$line"); done < <(python3 - "$INITMD" <<'PY'
import re, sys, json
text = open(sys.argv[1], encoding="utf-8").read()
for m in re.finditer(r"```bash\n(.*?)```", text, re.S):
    body = m.group(1)
    if re.search(r"idc_gh_board\.py.*\b(?:ensure-field|ensure-link)\b", body, re.S):
        print(json.dumps(body))
PY
)
[ "${#FENCES[@]}" -ge 1 ] || gov_fail "no provisioning fences found in init.md (extraction regex stale?)"
for f in "${FENCES[@]}"; do
  fence="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]))' "$f")"
  gate "$fence" "$SIN"
  is_deny && gov_fail "init.md provisioning fence DENIED under active init: [$fence] => [$OUT]"
  echo "  ok init.md provisioning fence allowed under active init"
done

echo "== multi-root GraphQL mutations receive no Init exception =="
deny_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}} closeIssue(input:{issueId:\"I\"}){issue{id}}}'"
# Even an all-project-field multi-root mutation is raw and denied.
deny_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}} createProjectV2Field(input:{}){projectV2Field{id}}}'"

echo "== round-10 Fix 4: leading shell CONTROL WORDS do not hide a segment's command head =="
# `else gh project link …` (init.md:201 uses this natural form) hid `gh` as the head, so `project link`
# fell through and was allowed under Think. Now leading control words/keywords
# (if/then/else/elif/fi/do/done/while/for/case/{/(/!/time) are skipped to find the real head.
# Red-when-broken: drop the control-word strip → `else gh project link` classifies as non-gh → allowed
# under Think.
deny 'else gh project link 5 --owner o --repo o/r'
deny 'then gh issue create --title x --body-file /tmp/b'
deny '! gh issue create --title x --body-file /tmp/b'
deny 'time gh project field-create 5 --owner o --name S --data-type SINGLE_SELECT --single-select-options X'
# The same raw write is denied under active Init too.
deny_under "$SIN" 'else gh project link 5 --owner o --repo o/r'

echo "== round-11 Fix 1: shell COMMENTS are stripped QUOTE-AWARE before classification =="
# A benign command carrying an INLINE comment that mentions the forbidden `gh api graphql -f query="$MUT"`
# form must NOT be denied — a `#` at a word boundary begins a shell comment, not executable text.
# Red-when-broken: drop the comment strip → the comment text classifies as an opaque graphql mutation → deny.
allow 'echo hi   # do NOT run: gh api graphql -f query="$MUT"'
allow $'echo hi\n# with a raw gh api graphql -f query="$MUT": the interlock hard-DENIES it\necho done'
# A `#` INSIDE single quotes is literal (part of the arg), NOT a comment — the real mutation still denies.
deny "gh api graphql -f query='mutation{updateIssue(input:{id:\"I#1\",state:CLOSED}){issue{id}}}'"
# The uncommented forbidden form still denies (the strip removes comments, never real commands).
deny 'gh api graphql -f query="$MUT"'
# A `#`-comment must not let a real mutation on a FOLLOWING line be swallowed (comment ends at newline,
# and a `\` inside a comment is NOT a line-continuation — comments are stripped BEFORE continuations join).
deny $'echo hi # trailing comment \\\ngh issue create --title x --body-file /tmp/b'

echo "== round-11 Fix 1: init.md AND update.md Stage-reconcile fences pass under active init/update =="
# The reviewer's real-surface proof: BOTH shipped Stage-reconcile fences carry an explanatory comment
# showing the forbidden `gh api graphql -f query="$MUT"` form, so before the strip both DENIED. Extract
# every fence that runs `gh api graphql` (the reconcile + link-probe fences) and assert NONE deny under
# the matching active command. Red-when-broken: drop the comment strip → the fence comment classifies as
# a mutation → the fence DENIES → this FAILs. (init.md fences were only covered when they contained
# field-create/link — the reconcile fence has neither, so this widens the extraction to catch it.)
SUP="sup-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SUP" --command update \
  --plugin-root "$GOV_PLUGIN" --args 'reconcile' --source user >/dev/null \
  || gov_fail "could not open the active /idc:update command record for $SUP"
extract_fences() {  # extract_fences <md-file> <regex> → populates FENCES[]
  # Bash 3.2-compatible read loop in place of `mapfile` (see note above): one JSON-line
  # fence per iteration; the python never emits a bare empty line.
  FENCES=()
  while IFS= read -r line; do FENCES+=("$line"); done < <(python3 - "$1" "$2" <<'PY'
import re, sys, json
text = open(sys.argv[1], encoding="utf-8").read()
pat = sys.argv[2]
for m in re.finditer(r"```bash\n(.*?)```", text, re.S):
    body = m.group(1)
    if re.search(pat, body):
        print(json.dumps(body))
PY
)
}
UPDATEMD="$GOV_PLUGIN/commands/update.md"
[ -f "$UPDATEMD" ] || gov_fail "commands/update.md not found at $UPDATEMD"
extract_fences "$INITMD" 'gh api graphql'
[ "${#FENCES[@]}" -ge 1 ] || gov_fail "no gh-api-graphql fences found in init.md (extraction regex stale?)"
for f in "${FENCES[@]}"; do
  fence="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]))' "$f")"
  gate "$fence" "$SIN"
  is_deny && gov_fail "init.md Stage-reconcile fence DENIED under active init: [$fence] => [$OUT]"
  echo "  ok init.md gh-api-graphql fence allowed under active init"
done
extract_fences "$UPDATEMD" 'gh api graphql'
[ "${#FENCES[@]}" -ge 1 ] || gov_fail "no gh-api-graphql fences found in update.md (extraction regex stale?)"
for f in "${FENCES[@]}"; do
  fence="$(python3 -c 'import json,sys;print(json.loads(sys.argv[1]))' "$f")"
  gate "$fence" "$SUP"
  is_deny && gov_fail "update.md Stage-reconcile fence DENIED under active update: [$fence] => [$OUT]"
  echo "  ok update.md gh-api-graphql fence allowed under active update"
done

echo "== round-11 Fix 2: a VARIABLE-DERIVED gh subcommand fails closed (read-vs-write unprovable) =="
# `gh issue "$op"` (op=create) hides the write because the operation token is an expansion the classifier
# cannot resolve → DENY during an active command. Red-when-broken: drop the dynamic-subcommand guard →
# the variable subcommand matches no combo → allowed.
deny 'gh issue "$op" --title x --body-file /tmp/b'
deny 'gh "$sub" merge 12 --squash'
# the reviewer's exact bypass: the inner `gh issue "$op"` creates an issue before the allowed outer
# `gh project link` — the dynamic subcommand inside the substitution DENIES the whole call under init.
deny_under "$SIN" 'gh project link 5 --owner o --repo "$(op=create; gh issue "$op" --title x --body x)"'
# a STATIC-read subcommand with a dynamic ARGUMENT stays ALLOWED (only the subcommand token is judged).
allow 'gh issue view "$num"'
allow 'gh pr view "$prnum" --json title'

echo "== round-11 Fix 3: value-taking interpreter options cannot hide the real script target =="
# `bash --rcfile <sanctioned>.py <fixture>/fire_gate.sh` — bash consumes the first path as --rcfile's
# value and runs the SECOND path as the script. The gate must consume --rcfile's value AND inspect the
# real script (fire_gate.sh). Red-when-broken: pick the first non-flag arg as the script → the sanctioned
# decoy is inspected, fire_gate.sh is never scanned → allowed.
deny "bash --rcfile '$GOV_PLUGIN/scripts/idc_transition.py' '$FIXTURE/fire_gate.sh'"
deny "bash --init-file '$GOV_PLUGIN/scripts/idc_transition.py' '$FIXTURE/fire_gate.sh'"
deny "bash --rcfile='$GOV_PLUGIN/scripts/idc_transition.py' '$FIXTURE/fire_gate.sh'"
# the --rcfile/--init-file VALUE is itself a SOURCED file → a malicious rcfile hidden behind a sanctioned
# decoy script still DENIES (EVERY path it would run OR source is inspected).
deny "bash --rcfile '$FIXTURE/fire_gate.sh' '$GOV_PLUGIN/scripts/idc_transition.py'"
# a plain sanctioned interpreter target with a sanctioned rcfile stays ALLOWED (no over-block).
allow "bash --rcfile '$GOV_PLUGIN/scripts/idc_pr_finish.py' '$GOV_PLUGIN/scripts/idc_transition.py'"

echo "== round-11 Fix 4: protected-gh detection is WRAPPER-AGNOSTIC (nohup/stdbuf/timeout/setsid/nice…) =="
# `nohup gh project field-create …` bypassed because nohup wasn't a recognized wrapper and the fallback
# verb list omitted project field-create/link. Detection now scans the token stream for a `gh` head after
# ANY leading wrapper. Red-when-broken: revert to first-token-must-be-gh → the wrapped op classifies as
# non-gh and is allowed under Think.
deny 'nohup gh project field-create 5 --owner o --name S --data-type SINGLE_SELECT --single-select-options X'
deny 'nohup gh project link 5 --owner o --repo o/r'
deny 'stdbuf -oL gh issue create --title x --body-file /tmp/b'
deny 'timeout 5 gh pr merge 12 --squash'
deny 'setsid gh issue create --title x --body-file /tmp/b'
deny 'nice -n 10 gh issue close 5'
# under an ACTIVE init the wrapped provisioning op is init's OWN static op → ALLOWED (wrapper-agnostic
# both ways).
deny_under "$SIN" 'nohup gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options "Consideration,Planning,Buildable,Recirculation"'
deny_under "$SIN" 'nohup gh project link 5 --owner o --repo o/r'
# a wrapped READ stays allowed (the scan flags only protected WRITE combos, never a read).
allow 'nohup gh issue view 5'

echo "== round-12 Fix 1: --rcfile/--init-file is inspected even when the SAME bash uses -c (no early return) =="
# `bash --rcfile <fire_gate.sh> -i -c 'echo hi'` SOURCES the rcfile BEFORE running the innocuous -c
# payload — so a protected mutation hidden in the rcfile must still DENY. Red-when-broken: return right
# after inspecting the -c payload → the rcfile is never scanned → allowed.
deny "bash --rcfile '$FIXTURE/fire_gate.sh' -i -c 'echo hi'"
deny "bash --init-file '$FIXTURE/fire_gate.sh' -i -c 'echo hi'"
deny "bash --rcfile='$FIXTURE/fire_gate.sh' -i -c 'echo hi'"
# and BOTH targets are inspected: a sanctioned rcfile with a WRITE -c payload still denies on the payload.
deny "bash --rcfile '$GOV_PLUGIN/scripts/idc_pr_finish.py' -i -c 'gh issue create --title x --body-file /tmp/b'"
# a sanctioned rcfile + an innocuous -c payload stays ALLOWED (no over-block from combining the two).
allow "bash --rcfile '$GOV_PLUGIN/scripts/idc_transition.py' -i -c 'echo hi'"

echo "== round-12 Fix 2: interpreter detection is WRAPPER-AGNOSTIC (nohup/timeout/stdbuf/setsid/nice…) =="
# `nohup bash <fire_gate.sh>` executes the script; the interpreter path must strip the SAME wrappers the
# gh path does before detecting bash|sh|zsh. Red-when-broken: strip only env/command/builtin/exec → the
# wrapped interpreter is not detected and the script is never inspected → allowed.
deny "nohup bash '$FIXTURE/fire_gate.sh'"
deny "timeout 5 bash '$FIXTURE/fire_gate.sh'"
deny "stdbuf -oL sh '$FIXTURE/fire_gate.sh'"
deny "setsid zsh '$FIXTURE/fire_gate.sh'"
deny "nice -n 10 bash '$FIXTURE/fire_gate.sh'"
deny "timeout -s KILL 5 bash '$FIXTURE/fire_gate.sh'"
deny "nohup source '$FIXTURE/fire_gate.sh'"
# a wrapped SANCTIONED interpreter target stays ALLOWED (wrapper-agnostic both ways, no over-block).
allow "nohup bash '$GOV_PLUGIN/scripts/idc_transition.py'"
allow "timeout 5 bash '$GOV_PLUGIN/scripts/idc_transition.py'"
# a NON-wrapper leading word must NOT be peeled — `grep bash <file>` is an ordinary read, never mistaken
# for `bash <file>` interpreter indirection (the numeric/alpha operand guard keeps the head honest).
allow "grep bash '$REPO/docs/workflow/tracker-config.yaml'"

echo "== round-12 Fix 3: -c inside a COMBINED short-flag cluster (-xc/-ic/-lc) is the command flag =="
# `bash -xc '<payload>'` — the trailing `c` in the cluster means the next arg is the -c command string,
# not a script filename. Red-when-broken: only an exact `-c` token is recognized → the quoted read is
# mis-treated as a filename → opaque-target over-DENY of a harmless static read.
allow "bash -xc 'gh issue view 5'"
allow "sh -lc 'gh pr view 12 --json title'"
allow "bash -ic 'echo hi'"
# a WRITE payload inside the same cluster still DENIES (the payload is recursed as a command).
deny "bash -xc 'gh issue create --title x --body-file /tmp/b'"
deny "bash -ic 'gh pr merge 12 --squash'"

echo "== round-13 Fix 1: an exec WRAPPER before \`env -S\` cannot smuggle the split-string command =="
# The `env -S`/startup-env/interpreter detection now runs on the segment AFTER leading exec wrappers /
# control words are stripped, so `nohup`/`timeout 5`/`stdbuf -oL`/`setsid`/`command` before an
# `env -S 'gh issue' create` no longer waves the reconstructed `gh issue create` through. Red-when-broken:
# check env-split on the RAW segment → a leading wrapper makes seg[0] != `env` → the payload is never
# parsed → the write is allowed.
deny "nohup env -S 'gh issue' create --title x"
deny "timeout 5 env -S 'gh issue' create --title x"
deny "stdbuf -oL env -S 'gh issue' create --title x"
deny "setsid env -S 'gh issue create --title x --body-file /tmp/b'"
deny "command env -S 'gh issue' create --title x"
# an exec wrapper before a BASH_ENV startup-file prefix likewise denies (startup-env on the stripped seg).
deny "nohup env BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
deny "timeout 5 env BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
# a wrapped `env -S` whose reconstructed command is a READ stays ALLOWED (no over-block).
allow "nohup env -S 'gh issue view 5'"

echo "== round-13 Fix 2: \`time -p\`/\`time --portability\` is a wrapper before the interpreter/gh head =="
# `time` is bash's keyword form `time [-p] pipeline`; the bare `time` was already handled as a control
# word, but `time -p`/`time --portability` left `-p` dangling so the interpreter/gh head was never reached.
# Red-when-broken: strip only the bare `time` token → `-p bash <fire>` has a non-interpreter head → allowed.
deny "time -p bash '$FIXTURE/fire_gate.sh'"
deny "time --portability sh '$FIXTURE/fire_gate.sh'"
deny "time -p gh issue create --title x --body-file /tmp/b"
# bare `time` (control-word path) still denies — no regression.
deny "time bash '$FIXTURE/fire_gate.sh'"
# `time -p` before a SANCTIONED interpreter target stays ALLOWED (no over-block).
allow "time -p bash '$GOV_PLUGIN/scripts/idc_transition.py'"

echo "== round-14: a benign leading assignment BEFORE a wrapper cannot smuggle the split-string/script =="
# Round-13 stopped the inspect-prefix strip at the FIRST leading VAR=val assignment, so it never peeled
# the FOLLOWING wrapper — `FOO=1 nohup env -S 'gh issue' create` left seg[0]=`FOO=1`, the env-split
# detector saw `nohup` (not `env`) after the assignment, and the reconstructed `gh issue create` slipped.
# A single fixpoint prefix-normalization loop now CROSSES ordinary assignments and PEELS wrappers/control
# words in ANY interleaving, stopping only at the real head (or at `env`/a startup-env assignment, whose
# payload must be inspected). Red-when-broken: stop the peel at any leading assignment → the wrapped
# `env -S`/script after it is never reached → the write is allowed.
deny "FOO=1 nohup env -S 'gh issue' create --title x"
deny "FOO=1 timeout 5 env -S 'gh issue' create --title x"
deny "FOO=1 command env -S 'gh issue' create --title x"
deny "FOO=1 setsid env -S 'gh issue create --title x --body-file /tmp/b'"
deny "FOO=1 stdbuf -oL env -S 'gh issue' create --title x"
deny "FOO=1 nice -n 10 env -S 'gh issue' create --title x"
# a benign assignment before a wrapped interpreter SCRIPT likewise denies (assignment→wrapper→bash FILE).
deny "FOO=1 nohup bash '$FIXTURE/fire_gate.sh'"
deny "FOO=1 timeout 5 bash '$FIXTURE/fire_gate.sh'"
deny "A=1 B=2 nohup bash '$FIXTURE/fire_gate.sh'"
# ANY interleaving order: an assignment AFTER a wrapper, and wrapper→assignment→wrapper→interpreter.
deny "nohup FOO=1 timeout 5 bash '$FIXTURE/fire_gate.sh'"
deny "FOO=1 nohup BAR=2 timeout 5 env -S 'gh issue' create --title x"
# a startup-env (BASH_ENV) assignment BEHIND a benign assignment + wrapper still denies (signal preserved).
deny "FOO=1 nohup env BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
deny "BAR=2 timeout 5 env BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
deny "FOO=1 nohup BASH_ENV='$FIXTURE/fire_gate.sh' bash -c 'echo hi'"
# NO over-block: a benign assignment before a wrapped READ / sanctioned script stays ALLOWED.
allow "FOO=1 nohup gh issue view 5"
allow "FOO=1 timeout 5 gh issue view 5"
allow "FOO=1 nohup env -S 'gh issue view 5'"
allow "FOO=1 nohup bash '$GOV_PLUGIN/scripts/idc_transition.py'"
allow "A=1 B=2 timeout 5 bash '$GOV_PLUGIN/scripts/idc_transition.py'"

echo "== rubber-stamp Fix 3: privilege wrappers cannot hide interpreter FILEs or payloads =="
deny "sudo bash '$FIXTURE/fire_gate.sh'"
deny "sudo -u root sh '$FIXTURE/fire_gate.sh'"
deny "doas zsh '$FIXTURE/fire_gate.sh'"
deny "doas -u root bash '$FIXTURE/fire_gate.sh'"
deny "su -c \"bash '$FIXTURE/fire_gate.sh'\" root"
deny "su root -c \"sh '$FIXTURE/fire_gate.sh'\""
deny "su --command=\"gh issue create --title gate --body-file /tmp/body\" root"

echo "== the sanctioned write door is never denied =="
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' create-ticket --title safe --stage Buildable --status Todo"
allow "python3 '$GOV_PLUGIN/scripts/idc_pr_finish.py' autonomous --repo '$REPO' --pr 12 --kind planning"
allow "python3 '$GOV_PLUGIN/scripts/idc_pr_gate_bind.py' --repo '$REPO' --pr 41 --gate 52"
allow_under "$SIN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' ensure-project --repo '$REPO' --owner o --title 'x IDC Tracker'"
allow_under "$SIN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' reconcile-status --repo '$REPO' --owner o --project 5"
allow_under "$SIN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' ensure-field --repo '$REPO' --owner o --project 5 --name Stage --option Consideration --option Planning --option Buildable --option Recirculation"
allow_under "$SIN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' ensure-link --repo '$REPO' --owner o --project 5 --repository o/r"
allow_under "$SUN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' close-project-issues --repo '$REPO' --owner o --project 5"
allow_under "$SUN" "python3 '$GOV_PLUGIN/scripts/idc_gh_board.py' delete-project --repo '$REPO' --owner o --project 5 --confirm 5"
# Fix 2: the sanctioned engine doors that REPLACE the now-denied raw item-edit / blocked_by POST.
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' set-field --num 5 --field Wave --value W1"
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' link --parent 7 --child 5 --kind blocks"

echo "== raw PR body edits stay denied and name the reciprocal binder =="
gate "gh pr edit 41 --body 'manual marker'" "$S1"
is_deny || gov_fail "raw gh pr edit was not denied during an active command"
printf '%s' "$OUT" | grep -qF "$GOV_PLUGIN/scripts/idc_pr_gate_bind.py" \
  || gov_fail "raw gh pr edit denial did not name the sanctioned reciprocal binder: $OUT"
echo "  ok raw gh pr edit denies with idc_pr_gate_bind.py remediation"

echo "== the denial remediation names the REAL plugin path, never the literal token (Fix 6) =="
gate "cd wt && gh pr merge 12 --squash" "$S1"
is_deny || gov_fail "(fix6) a raw merge during an active command must deny"
printf '%s' "$OUT" | grep -q '${CLAUDE_PLUGIN_ROOT}' \
  && gov_fail "(fix6) the denial emitted the literal \${CLAUDE_PLUGIN_ROOT} token (unusable recovery command)"
printf '%s' "$OUT" | grep -qF "$GOV_PLUGIN/scripts/idc_" \
  || gov_fail "(fix6) the denial did not interpolate the real plugin path ($GOV_PLUGIN/scripts/…): [$OUT]"
echo "  ok the denial remediation interpolates the real plugin path (no literal token)"

echo "== outside an active command, the same raw mutation still HARD DENIES (missing auth is blocking) =="
gate 'gh issue create --title gate --body-file /tmp/body' "$SNONE"
[ "$RC" -eq 0 ] || gov_fail "(inactive) gate exit $RC, expected 0 (a hook signals via JSON, not exit code)"
is_deny || gov_fail "(inactive) a non-active session did not deny raw gh issue create: stdout=[$OUT] stderr=[$(cat "$ERR")]"
gate "bash '$FIXTURE/fire_gate.sh'" "$SNONE"
is_deny || gov_fail "(inactive) a non-active session did not deny interpreter indirection: stdout=[$OUT] stderr=[$(cat "$ERR")]"
echo "  ok non-active session ⇒ hard deny for the direct raw write AND its interpreter-indirection form"

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

echo "== a sensitive target is DENIED WITHOUT being opened — proven via an unreadable FIFO (Fix 9) =="
# A FIFO opened for reading with no writer BLOCKS forever. If the interlock opened this target the
# gate would HANG; the sensitive-name refusal must fire BEFORE any open, so the gate returns promptly.
FIFO="$WORK/.env"; rm -f "$FIFO"; mkfifo "$FIFO"
FOUT="$(emit "$REPO" Bash "source '$FIFO'" "$S1" | timeout 10 python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; FRC=$?
[ "$FRC" -ne 124 ] || gov_fail "(fix9) the gate HUNG on a sensitive FIFO — it must refuse before opening it"
printf '%s' "$FOUT" | grep -q '"permissionDecision": *"deny"' \
  || gov_fail "(fix9) sensitive FIFO source was not denied: [$FOUT][$(cat "$ERR")]"
printf '%s%s' "$FOUT" "$(cat "$ERR")" | grep -qi 'sensitive' \
  || gov_fail "(fix9) FIFO .env was not refused via the SENSITIVE path (denied as a plain opaque target instead?): [$FOUT]"
rm -f "$FIFO"
echo "  ok sensitive FIFO ⇒ denied promptly via the sensitive path, never opened (no hang)"

echo "== round-6 Fix 4: a SYMLINK aliasing a sensitive target is refused on the RESOLVED path, unopened =="
# Sensitivity/plugin/regular-file checks must run on realpath() FIRST, then open only the resolved
# path — else a `safe.sh` symlink → `.env` is opened and its secret scanned/echoed.
mkdir -p "$WORK/d1"; ENVT="$WORK/d1/.env"; SENTINEL2='SENTINEL_SYMLINK_LEAK_x7q_MUST_NOT_APPEAR'
printf 'export TOKEN=%s\n' "$SENTINEL2" > "$ENVT"
ln -sf "$ENVT" "$WORK/safe.sh"
gate "bash '$WORK/safe.sh'" "$S1"
is_deny || gov_fail "(fix4) a symlink to .env must be DENIED on the resolved path: [$OUT][$(cat "$ERR")]"
if printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -q "$SENTINEL2"; then
  gov_fail "(fix4) the interlock READ a symlink-aliased .env and echoed its content — it must never open a sensitive target"
fi
printf '%s%s' "$OUT" "$(cat "$ERR")" | grep -qi 'sensitive' \
  || gov_fail "(fix4) the symlink→.env was not refused via the SENSITIVE path: [$OUT][$(cat "$ERR")]"
# Prove non-opening deterministically: point the symlink at a sensitive FIFO — opening it would HANG.
mkdir -p "$WORK/d2"; FIFOT="$WORK/d2/.env"; rm -f "$FIFOT"; mkfifo "$FIFOT"; ln -sf "$FIFOT" "$WORK/safe2.sh"
FOUT="$(emit "$REPO" Bash "bash '$WORK/safe2.sh'" "$S1" | timeout 10 python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; FRC=$?
[ "$FRC" -ne 124 ] || gov_fail "(fix4) the gate HUNG on a symlink to a sensitive FIFO — realpath+sensitive check must precede any open"
printf '%s' "$FOUT" | grep -q '"permissionDecision": *"deny"' \
  || gov_fail "(fix4) symlink→FIFO .env was not denied: [$FOUT][$(cat "$ERR")]"
rm -f "$FIFOT"
echo "  ok symlink→.env (and →FIFO) ⇒ denied on the resolved path via the sensitive lane, never opened"

echo "PASS: the mutation interlock is a hard deny both without a live authorization and during an active IDC command, sees through bash/sh/zsh/source/. indirection and quoted bash -c payloads, protects gh issue create + dependency REST writes, downgrades under OBSERVE_ONLY, and refuses opaque/sensitive interpreter targets unread"
