#!/bin/bash
# post-issue-not-board-added.sh — governance scenario: the PostToolUse issue-create-add
# board-coherence observer (v4 Phase 3 Stage D, §3.2 "PostToolUse (gh issue create)").
#
# The invariant: after a SUCCESSFUL `gh issue create`, if the SAME shell command did not also route
# the new issue onto the project board (through the single write door `idc_transition.py`, or a raw
# `gh project item-add`), the observer injects the exact remediation as PostToolUse additionalContext
# naming the concrete next steps (with the real engine path, and — on the github backend — the
# `--backend github --owner --project` coordinates the move op requires). It NEVER emits a block
# decision (fail-open, ALWAYS), never fires a live board GraphQL scan, and never fires on a create that
# did not land / non-Bash tool / non-governed repo / a command that already chains a board-add.
#
# SUCCESS IS INFERRED FROM OUTPUT TEXT, not an exit code: the real Bash PostToolUse tool_response has
# NO exit_code field (only stdout/stderr/interrupted) — a successful `gh issue create` prints the new
# issue URL. This scenario drives the REAL shape (never a fabricated exit_code, which would certify a
# hook that is dead in production).
#
# Red-when-broken: neuter idc_post_issue_create._same_command_added_to_board (make it always return
# True) → the (N) bare-create headline case stops injecting → this scenario FAILs. Dropping the github
# coordinates from the remediation defeats (GH).
#
#   (N) bare `gh issue create` (no board-add chained), fs backend ⇒ INJECT the real engine path [headline]
#   (GH) bare create on the GITHUB backend ⇒ remediation carries `--backend github --owner --project`
#   (C) `gh issue create && … idc_transition.py …` (chained) ⇒ NO output (coherent)
#   (P) `gh issue create && gh project item-add …` (chained, raw attach) ⇒ NO output (still "added")
#   (F) the `gh issue create` did NOT land (no issue URL in output) ⇒ NO output
#   (I) the create was interrupted ⇒ NO output
#   (A) `gh issue list` (not a create) ⇒ NO output (self-gated)
#   (W) a non-Bash tool ⇒ NO output (self-gated)
#   (G) non-governed repo ⇒ NO output (repo-gated)
#
# Usage: bash tests/smoke/governance/post-issue-not-board-added.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OBS="$GOV_PLUGIN/scripts/hooks/idc_post_issue_create.py"
[ -f "$OBS" ] || gov_fail "idc_post_issue_create.py not found at $OBS (not implemented yet)"
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
REPO_GH="$WORK/repo-gh"; mkdir -p "$REPO_GH/docs/workflow"
printf 'backend: github\n' > "$REPO_GH/docs/workflow/tracker-config.yaml"
NONGOV="$WORK/plain"; mkdir -p "$NONGOV"   # no docs/workflow/tracker-config.yaml

# emit <cwd> <tool> <command> <stdout> <stderr> <interrupted> -> a PostToolUse payload on stdout,
# in the REAL Bash tool_response shape (stdout/stderr/interrupted — NO exit_code).
emit() {
  CWD="$1" TOOL="$2" CMD="$3" OUT="$4" ERRTXT="$5" INT="$6" python3 -c \
    'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"session_id":"govtest-issue","tool_input":{"command":os.environ["CMD"]},"tool_response":{"stdout":os.environ["OUT"],"stderr":os.environ["ERRTXT"],"interrupted":os.environ["INT"]=="true","isImage":False}}))'
}

ERR="$WORK/err"
# run <cwd> <tool> <command> <stdout> [stderr] [interrupted] -> runs the observer; $RES/$RC set.
run() { RES="$(emit "$1" "$2" "$3" "$4" "${5:-}" "${6:-false}" | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

CREATE="gh issue create --title 'a stray issue' --body 'no board add here'"
CREATE_URL="https://github.com/o/r/issues/999"
CREATE_URL_GH="https://github.com/o/r/issues/888"

# ── (N) bare create, nothing chained, fs backend ⇒ inject (headline) ────────────────────────────────
run "$REPO" Bash "$CREATE" "$CREATE_URL"
[ "$RC" -eq 0 ] || gov_fail "(N) observer exit was $RC, expected 0 (fail-open, always)"
printf '%s' "$RES" | grep -q '"additionalContext"' || gov_fail "(N) no additionalContext injected: $RES"
printf '%s' "$RES" | grep -qF "$ENGINE" || gov_fail "(N) remediation must name the REAL engine path ($ENGINE): $RES"
printf '%s' "$RES" | grep -qF '${CLAUDE_PLUGIN_ROOT}' && gov_fail "(N) remediation must NOT embed the literal \${CLAUDE_PLUGIN_ROOT} token (unrunnable): $RES"
printf '%s' "$RES" | grep -q '999' || gov_fail "(N) remediation did not reference the parsed issue #999: $RES"
printf '%s' "$RES" | grep -qF -- '--backend github' && gov_fail "(N) fs backend remediation must NOT carry github coords: $RES"
printf '%s' "$RES" | grep -q '"decision"' && gov_fail "(N) must NEVER emit a decision/block field: $RES"
echo "  ok (N) bare 'gh issue create' (fs) ⇒ inject the real engine path, no github coords [headline]"

# ── (GH) bare create on the github backend ⇒ remediation carries github coordinates ─────────────────
run "$REPO_GH" Bash "$CREATE" "$CREATE_URL_GH"
printf '%s' "$RES" | grep -q '"additionalContext"' || gov_fail "(GH) github backend should still inject: $RES"
printf '%s' "$RES" | grep -qF -- '--backend github --owner <owner> --project <n>' \
  || gov_fail "(GH) github remediation must carry '--backend github --owner <owner> --project <n>' or the move fails: $RES"
printf '%s' "$RES" | grep -q '888' || gov_fail "(GH) github remediation did not reference issue #888: $RES"
echo "  ok (GH) bare create on github backend ⇒ remediation carries --backend github --owner --project coords"

# ── (C) chained with idc_transition.py ⇒ coherent, no output ────────────────────────────────────────
run "$REPO" Bash "$CREATE && python3 \${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo . recirculate-intake --title x" "$CREATE_URL"
[ -z "$RES" ] || gov_fail "(C) a command chained with idc_transition.py must produce NO output: $RES"
echo "  ok (C) 'gh issue create && … idc_transition.py …' ⇒ coherent, no output"

# ── (P) chained with a raw gh project item-add ⇒ still counted as 'added', no output ────────────────
run "$REPO" Bash "$CREATE && gh project item-add 8 --owner me --url $CREATE_URL" "$CREATE_URL"
[ -z "$RES" ] || gov_fail "(P) a command chained with 'gh project item-add' must produce NO output: $RES"
echo "  ok (P) 'gh issue create && gh project item-add …' ⇒ counted as added, no output"

# ── (F) the create did NOT land (no issue URL) ⇒ no output ──────────────────────────────────────────
run "$REPO" Bash "$CREATE" "" "error: could not create issue"
[ -z "$RES" ] || gov_fail "(F) a create with no issue URL in output must produce NO output: $RES"
echo "  ok (F) a create that did not land (no issue URL, no exit_code) ⇒ no output"

# ── (I) the create was interrupted ⇒ no output ──────────────────────────────────────────────────────
run "$REPO" Bash "$CREATE" "$CREATE_URL" "" true
[ -z "$RES" ] || gov_fail "(I) an interrupted create must produce NO output even with a URL in stdout: $RES"
echo "  ok (I) an interrupted create ⇒ no output"

# ── (A) a non-create gh issue command ⇒ self-gated no-op ───────────────────────────────────────────
run "$REPO" Bash "gh issue list --limit 30" ""
[ -z "$RES" ] || gov_fail "(A) 'gh issue list' must produce NO output: $RES"
echo "  ok (A) 'gh issue list' (not a create) ⇒ self-gated no-op"

# ── (W) a non-Bash tool ⇒ self-gated no-op ──────────────────────────────────────────────────────────
run "$REPO" Write "$CREATE" "$CREATE_URL"
[ -z "$RES" ] || gov_fail "(W) a non-Bash tool must produce NO output: $RES"
echo "  ok (W) a non-Bash tool ⇒ self-gated no-op"

# ── (G) non-governed repo ⇒ repo-gated no-op ────────────────────────────────────────────────────────
run "$NONGOV" Bash "$CREATE" "$CREATE_URL"
[ -z "$RES" ] || gov_fail "(G) fired outside a governed repo: $RES"
echo "  ok (G) non-governed repo ⇒ repo-gated no-op"

echo "PASS: PostToolUse issue-create-add — a bare 'gh issue create' not chained with a board-add injects the real-path idc_transition.py remediation naming the parsed issue number (with github coordinates on the github backend); a chained/added command, a create that did not land, an interrupted create, a non-create gh command, non-Bash tools, and non-governed repos are all untouched"
