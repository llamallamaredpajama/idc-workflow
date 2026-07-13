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
# a DYNAMIC-endpoint gh api READ (no write indicator) stays ALLOWED outside a carve-out (never over-blocks).
allow "gh api \"\$EP\" --jq .foo"

echo "== round-5 Fix 2: /idc:uninstall's own teardown ops are ALLOWED during an ACTIVE uninstall =="
# The hard deny must not brick uninstall's documented --close-issues / --delete-board steps. The
# allowance is keyed on the ACTIVE command being `uninstall`; the SAME raw ops under any other command
# stay denied, and non-teardown mutations stay denied even during uninstall.
SUN="sun-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SUN" --command uninstall \
  --plugin-root "$GOV_PLUGIN" --args 'teardown' --source user >/dev/null \
  || gov_fail "could not open the active /idc:uninstall command record for $SUN"

allow_under() {  # allow_under <session> <cmd> — must NOT deny or warn.
  gate "$2" "$1"
  [ "$RC" -eq 0 ] || gov_fail "ALLOW expected exit 0 but got $RC: [$2]"
  [ -z "$OUT" ] || gov_fail "ALLOW expected no permission decision but got one: [$2] => [$OUT]"
  grep -q 'IDC interlock' "$ERR" && gov_fail "ALLOW wrongly flagged during uninstall: [$2] => [$(cat "$ERR")]"
  echo "  ok allow (uninstall teardown): $2"
}
deny_under() {  # deny_under <session> <cmd> — must hard-deny under that session.
  gate "$2" "$1"
  is_deny || gov_fail "DENY expected under session but not denied: [$2]  stdout=[$OUT] stderr=[$(cat "$ERR")]"
  echo "  ok deny: $2"
}

# uninstall OWNS these teardown ops → ALLOWED while an uninstall command is active.
allow_under "$SUN" "gh issue close 5"
allow_under "$SUN" "gh project delete 8 --owner o"
allow_under "$SUN" "gh project item-delete 8 --owner o --id PVTI_X"
# The SAME teardown ops under a NON-uninstall active command (think = S1) stay DENIED (keyed on uninstall).
deny_under "$S1" "gh issue close 5"
deny_under "$S1" "gh project delete 8 --owner o"
# Non-teardown mutations stay DENIED even DURING uninstall (the allowance is scoped to what it owns).
deny_under "$SUN" "gh issue create --title x --body-file /tmp/b"
deny_under "$SUN" "gh pr merge 12 --squash"
deny_under "$SUN" "gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE"
deny_under "$SUN" "gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O"
# round-6 Fix 3: a forbidden mutation SMUGGLED after an allowed teardown must DENY the WHOLE call —
# EVERY segment must be a teardown op, not just the first one classification happens to return.
deny_under "$SUN" "gh issue close 5 && gh issue create --title x --body-file /tmp/b"
deny_under "$SUN" "gh issue close 5 && gh api repos/o/r/issues/707/dependencies/blocked_by/708 -X DELETE"
deny_under "$SUN" "bash -c 'gh issue close 5; gh api graphql --input mutation.json'"
# round-7 Fix 2: a `gh \`+newline+`issue create` smuggled after an allowed teardown must DENY the whole
# call — line-continuations are collapsed before segmentation, so the joined `gh issue create` is seen.
deny_under "$SUN" $'gh issue close 5 && gh \\\nissue create --title x --body-file /tmp/b'
# A compound of teardown-ONLY ops stays allowed under uninstall (the carve-out still works).
allow_under "$SUN" "gh issue close 5 && gh project item-delete 8 --owner o --id PVTI_X"
# round-9 Fix A (finding 3): a $()-command-substitution / backtick smuggled into an ALLOWED teardown op's
# ARGUMENT executes the inner mutation before the outer close — a carve-out allows ONLY fully STATIC
# recognized ops, so ANY dynamic construct DENIES the whole call. Red-when-broken: drop the carve-out
# dynamic guard → the inner `gh issue create` rides along inside the --comment value and the deny stops.
deny_under "$SUN" "gh issue close 5 --comment \"\$(gh issue create --title x --body x)\""
deny_under "$SUN" "gh issue close 5 --comment \"\`gh issue create --title x --body x\`\""

echo "== round-8 Fix 3: /idc:init's OWN board provisioning is ALLOWED during an ACTIVE init =="
# Symmetric to the uninstall teardown carve-out: a command may perform its OWN declared
# lifecycle/provisioning ops. Init opens its lifecycle record after creating tracker-config, then
# provisions the board — field creation, project link, and the Status option-reconcile GraphQL
# mutation have no engine door, so the hard deny would brick a governed Init. They are ALLOWED ONLY
# while an `init` command is active; the SAME raw ops under any other command stay DENIED, and every
# OTHER protected mutation stays denied even during init. Red-when-broken: drop the init carve-out →
# the provisioning allow_under cases start denying.
SIN="sin-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SIN" --command init \
  --plugin-root "$GOV_PLUGIN" --args 'provision' --source user >/dev/null \
  || gov_fail "could not open the active /idc:init command record for $SIN"

# init OWNS these provisioning ops → ALLOWED while an init command is active.
allow_under "$SIN" 'gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options "Consideration,Planning,Buildable,Recirculation"'
allow_under "$SIN" 'gh project link 5 --owner o --repo o/r'
allow_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\",singleSelectOptions:[{name:\"Todo\",color:GRAY}]}){projectV2Field{id}}}'"
# The SAME provisioning ops under a NON-init active command (think = S1) stay DENIED (keyed on init).
deny_under "$S1" 'gh project field-create 5 --owner o --name Stage --data-type SINGLE_SELECT --single-select-options "Consideration"'
deny_under "$S1" 'gh project link 5 --owner o --repo o/r'
deny_under "$S1" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}}}'"
# Every OTHER protected mutation stays DENIED even DURING init (the carve-out is scoped to provisioning).
deny_under "$SIN" 'gh issue create --title x --body-file /tmp/b'
deny_under "$SIN" 'gh pr merge 12 --squash'
deny_under "$SIN" 'gh project item-edit --id X --project-id Y --field-id F --single-select-option-id O'
deny_under "$SIN" 'gh project delete 8 --owner o'
deny_under "$SIN" "gh api graphql -f query='mutation{updateIssue(input:{id:\"I\",state:CLOSED}){issue{id}}}'"

echo "== round-9 Fix A (finding 3): a dynamic construct beside an ALLOWED provisioning op DENIES under init =="
# A $()-command-substitution / process-substitution smuggled into an allowed `gh project link` argument
# executes the inner mutation — under init only fully STATIC provisioning ops are allowed. Red-when-broken:
# drop the carve-out dynamic guard → the inner `gh issue create` rides along inside --repo and allows.
deny_under "$SIN" "gh project link 5 --owner o --repo \"\$(gh issue create --title x --body x)\""
deny_under "$SIN" "gh project link 5 --owner o --repo <(gh issue create --title x)"

echo "== round-9 Fix B: init's graphql provisioning carve-out classifies the ROOT mutation, not a substring =="
# The carve-out must key on the REAL root mutation field, not any substring of the query text. A sanctioned
# provisioning name appearing only in a trailing GraphQL COMMENT does NOT qualify (root is closeIssue → the
# whole call DENIES under init); a real root `updateProjectV2Field` still qualifies (ALLOW). Red-when-broken:
# revert _graphql_is_provision to the whole-value substring scan → the comment-smuggle is misclassified as
# provisioning and allowed under init.
deny_under "$SIN" "gh api graphql -f query='mutation{closeIssue(input:{issueId:\"I\"}){issue{id}}} # updateProjectV2Field'"
allow_under "$SIN" "gh api graphql -f query='mutation{updateProjectV2Field(input:{fieldId:\"F\"}){projectV2Field{id}}}'"

echo "== the sanctioned write door is never denied =="
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' create-ticket --title safe --stage Buildable --status Todo"
allow "python3 '$GOV_PLUGIN/scripts/idc_pr_finish.py' autonomous --repo '$REPO' --pr 12 --kind planning"
# Fix 2: the sanctioned engine doors that REPLACE the now-denied raw item-edit / blocked_by POST.
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' set-field --num 5 --field Wave --value W1"
allow "python3 '$GOV_PLUGIN/scripts/idc_transition.py' --repo '$REPO' link --parent 7 --child 5 --kind blocks"

echo "== the denial remediation names the REAL plugin path, never the literal token (Fix 6) =="
gate "cd wt && gh pr merge 12 --squash" "$S1"
is_deny || gov_fail "(fix6) a raw merge during an active command must deny"
printf '%s' "$OUT" | grep -q '${CLAUDE_PLUGIN_ROOT}' \
  && gov_fail "(fix6) the denial emitted the literal \${CLAUDE_PLUGIN_ROOT} token (unusable recovery command)"
printf '%s' "$OUT" | grep -qF "$GOV_PLUGIN/scripts/idc_" \
  || gov_fail "(fix6) the denial did not interpolate the real plugin path ($GOV_PLUGIN/scripts/…): [$OUT]"
echo "  ok the denial remediation interpolates the real plugin path (no literal token)"

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

echo "PASS: the mutation interlock is a hard deny during an active IDC command, sees through bash/sh/zsh/source/. indirection and quoted bash -c payloads, protects gh issue create + dependency REST writes, downgrades under OBSERVE_ONLY, warns (never bricks) outside an active command, and refuses opaque/sensitive interpreter targets unread"
