#!/bin/bash
# post-commit-unclaimed.sh — governance scenario: the PostToolUse commit-sync board-coherence
# observer (v4 Phase 3 Stage D, §3.2 "PostToolUse (git commit)").
#
# The invariant: after a SUCCESSFUL `git commit` on a branch/message that names a linked board item,
# if that item isn't Status=In Progress, the observer either auto-repairs it (via `idc_transition.py
# move --to-status "In Progress"`, the single write door) or — when repair isn't possible (e.g. the
# item is terminal) — injects the exact remediation as PostToolUse additionalContext. It NEVER emits a
# block decision (fail-open, ALWAYS), never fires on a commit that didn't land / non-Bash tool /
# non-governed repo / undeterminable linkage, and never queries a live board.
#
# SUCCESS IS INFERRED FROM OUTPUT TEXT, not an exit code: the real Claude Code Bash PostToolUse
# tool_response has NO exit_code field (only stdout/stderr/interrupted), so this scenario drives the
# REAL shape — a landed commit's `[branch sha] … N file changed` output vs. a rejected commit's
# "nothing to commit" — never a fabricated exit_code (which would certify a hook that is dead in prod).
#
# Red-when-broken: neuter idc_post_commit_sync._fs_move_in_progress (make it always return False, i.e.
# auto-repair never happens) → the (R) repair-then-silent case starts emitting a remediation instead of
# staying silent → this scenario FAILs (case R's "no stdout" assertion trips). The precedence fix (X)
# is defeated by ranking a bare `#N` above the branch in resolve_linked_item (repairs the wrong item);
# the github rate-limit (H) by dropping the once-per-item latch.
#
#   (R) drifted item (Todo), git commit references it ⇒ auto-REPAIRED (move → In Progress), NO output [headline]
#   (X) branch number OUTRANKS an incidental bare `#N` in the message ⇒ the BRANCH item is repaired,
#       the bare-`#N` item is left untouched (a wrong-item mutation is not fail-open-safe)
#   (Z) linkage is ONLY a bare `#N` (no trailer, non-numeric branch) ⇒ undeterminable ⇒ NO output
#   (T) item already In Progress ⇒ coherent, NO output (nothing to repair)
#   (D) item terminal (Done) ⇒ repair refused (Done cannot be resurrected) ⇒ INJECT the real engine path
#   (O) same as (R) but IDC_HOOKS_OBSERVE_ONLY=1 ⇒ NOT auto-repaired (status stays Todo) + INJECT instead
#   (H) github backend ⇒ local-only check, INJECT a reminder naming `--backend github` coords, ONCE per
#       (session,item) — a second commit for the same item is silent (no per-commit nag)
#   (U) commit message/branch names no item ⇒ undeterminable linkage ⇒ NO output
#   (F) `git commit` did NOT land (rejected: "nothing to commit") ⇒ NO output
#   (B) a non-`git commit` Bash command ⇒ NO output (self-gated)
#   (W) a non-Bash tool ⇒ NO output (self-gated)
#   (G) non-governed repo ⇒ NO output (repo-gated)
#
# Usage: bash tests/smoke/governance/post-commit-unclaimed.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

OBS="$GOV_PLUGIN/scripts/hooks/idc_post_commit_sync.py"
[ -f "$OBS" ] || gov_fail "idc_post_commit_sync.py not found at $OBS (not implemented yet)"
ENGINE="$GOV_PLUGIN/scripts/idc_transition.py"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
git -C "$REPO" init -q
git -C "$REPO" config user.email gov@example.com
git -C "$REPO" config user.name "Governance Test"
NONGOV="$WORK/plain"; mkdir -p "$NONGOV"   # no docs/workflow/tracker-config.yaml

TRK="$REPO/TRACKER.md"
python3 "$GOV_TRK" --tracker "$TRK" init >/dev/null || gov_fail "could not init throwaway TRACKER.md"

# A realistic landed-`git commit` stdout (header `[branch sha]` + diffstat) and a rejected-commit
# stderr ("nothing to commit") — this is exactly what the real Bash tool_response carries.
LANDED_OUT='[somebranch 1a2b3c4] a commit message
 1 file changed, 1 insertion(+)'
REJECTED_ERR='On branch main
nothing to commit, working tree clean'

# seed_commit <branch> <message> — makes an empty-ish commit on a fresh branch off main so each case
# gets its own HEAD commit + branch name to parse the linkage from.
seed_commit() {
  local branch="$1" msg="$2"
  git -C "$REPO" checkout -q -B "$branch" >/dev/null 2>&1
  date +%s%N > "$REPO/touch.$branch"
  git -C "$REPO" add "touch.$branch" >/dev/null
  git -C "$REPO" commit -q -m "$msg" >/dev/null
}

# emit <cwd> <command> <stdout> <stderr> <interrupted> [tool] -> a PostToolUse payload on stdout,
# in the REAL Bash tool_response shape (stdout/stderr/interrupted — NO exit_code).
emit() {
  CWD="$1" CMD="$2" OUT="$3" ERRTXT="$4" INT="$5" TOOL="${6:-Bash}" SID="${SID:-govtest-commit}" python3 -c \
    'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"session_id":os.environ["SID"],"tool_input":{"command":os.environ["CMD"]},"tool_response":{"stdout":os.environ["OUT"],"stderr":os.environ["ERRTXT"],"interrupted":os.environ["INT"]=="true","isImage":False,"noOutputExpected":False}}))'
}

ERR="$WORK/err"
# run <cwd> <command> — a SUCCESSFUL landed commit (LANDED_OUT); sets $RES (stdout) + $RC + $ERR.
run() { RES="$(emit "$1" "$2" "$LANDED_OUT" "" false | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

# ── (R) drifted item ⇒ auto-repaired silently (headline) ───────────────────────────────────────────
NUM_R="$(gov_seed_item "$TRK" --title 'drifted item' --stage Buildable --status Todo)" \
  || gov_fail "(R) could not seed the drifted item"
seed_commit "issue-$NUM_R-fix-thing" "fix the thing

Issue: #$NUM_R
"
run "$REPO" "git commit -m x"
[ "$RC" -eq 0 ] || gov_fail "(R) observer exit was $RC, expected 0 (fail-open, always)"
[ -z "$RES" ] || gov_fail "(R) auto-repair should leave NO stdout output: $RES"
[ "$(gov_field "$TRK" "$NUM_R" Status)" = "In Progress" ] \
  || gov_fail "(R) item #$NUM_R Status did not land at 'In Progress' after auto-repair"
echo "  ok (R) drifted (Todo) item referenced by the commit ⇒ auto-repaired to In Progress, no output [headline]"

# ── (X) branch number OUTRANKS an incidental bare #N in the message ─────────────────────────────────
NUM_X="$(gov_seed_item "$TRK" --title 'branch-linked item' --stage Buildable --status Todo)" \
  || gov_fail "(X) could not seed the branch-linked item"
NUM_OTHER="$(gov_seed_item "$TRK" --title 'incidentally cross-referenced item' --stage Buildable --status Todo)" \
  || gov_fail "(X) could not seed the cross-referenced item"
# branch carries NUM_X (a reliable signal); the message mentions #NUM_OTHER only as a cross-ref (NO trailer).
seed_commit "$NUM_X-fix-thing" "do the work

follow-up to #$NUM_OTHER
"
run "$REPO" "git commit -m x"
[ -z "$RES" ] || gov_fail "(X) branch-linked repair should be silent: $RES"
[ "$(gov_field "$TRK" "$NUM_X" Status)" = "In Progress" ] \
  || gov_fail "(X) the BRANCH item #$NUM_X must be the one repaired (branch outranks a bare #N)"
[ "$(gov_field "$TRK" "$NUM_OTHER" Status)" = "Todo" ] \
  || gov_fail "(X) the incidentally cross-referenced item #$NUM_OTHER must NEVER be mutated by a bare #N"
echo "  ok (X) branch number outranks an incidental bare #N ⇒ branch item repaired, cross-ref item untouched"

# ── (Z) linkage is ONLY a bare #N ⇒ undeterminable, no output ───────────────────────────────────────
NUM_Z="$(gov_seed_item "$TRK" --title 'bare-hash-only item' --stage Buildable --status Todo)" \
  || gov_fail "(Z) could not seed the bare-hash-only item"
seed_commit "chore-no-number" "some chore

Refs #$NUM_Z
"
run "$REPO" "git commit -m x"
[ -z "$RES" ] || gov_fail "(Z) a bare #N with no trailer and a non-numeric branch must be undeterminable ⇒ no output: $RES"
[ "$(gov_field "$TRK" "$NUM_Z" Status)" = "Todo" ] \
  || gov_fail "(Z) a bare-#N-only reference must never drive a mutation (item #$NUM_Z changed)"
echo "  ok (Z) bare #N only (no trailer, non-numeric branch) ⇒ undeterminable linkage, no output"

# ── (T) already coherent ⇒ no output, no-op ─────────────────────────────────────────────────────────
NUM_T="$(gov_seed_item "$TRK" --title 'coherent item' --stage Buildable --status "In Progress")" \
  || gov_fail "(T) could not seed the coherent item"
seed_commit "issue-$NUM_T-already-claimed" "more work

Issue: #$NUM_T
"
run "$REPO" "git commit -m x"
[ -z "$RES" ] || gov_fail "(T) an already-coherent item must produce NO output: $RES"
[ "$(gov_field "$TRK" "$NUM_T" Status)" = "In Progress" ] || gov_fail "(T) coherent item's Status must be untouched"
echo "  ok (T) item already In Progress ⇒ coherent, no output"

# ── (D) terminal item ⇒ repair refused ⇒ inject the real engine path ────────────────────────────────
NUM_D="$(gov_seed_item "$TRK" --title 'done item' --stage Buildable --status Done)" \
  || gov_fail "(D) could not seed the terminal item"
seed_commit "issue-$NUM_D-touch-done" "touch a done item

Issue: #$NUM_D
"
run "$REPO" "git commit -m x"
[ "$RC" -eq 0 ] || gov_fail "(D) observer exit was $RC, expected 0 (fail-open, always — even on a refused repair)"
printf '%s' "$RES" | grep -q '"additionalContext"' || gov_fail "(D) no additionalContext injected: $RES"
printf '%s' "$RES" | grep -qF "$ENGINE" || gov_fail "(D) remediation must name the REAL engine path ($ENGINE), not a token: $RES"
printf '%s' "$RES" | grep -qF '${CLAUDE_PLUGIN_ROOT}' && gov_fail "(D) remediation must NOT embed the literal \${CLAUDE_PLUGIN_ROOT} token (unrunnable): $RES"
printf '%s' "$RES" | grep -q '"decision"' && gov_fail "(D) must NEVER emit a decision/block field: $RES"
[ "$(gov_field "$TRK" "$NUM_D" Status)" = "Done" ] || gov_fail "(D) a terminal item must never be mutated by this observer"
echo "  ok (D) terminal (Done) item ⇒ repair refused ⇒ inject the real engine path, item left Done"

# ── (O) OBSERVE_ONLY suppresses the repair mutation, injects instead ────────────────────────────────
NUM_O="$(gov_seed_item "$TRK" --title 'observe-only item' --stage Buildable --status Todo)" \
  || gov_fail "(O) could not seed the drifted item"
seed_commit "issue-$NUM_O-observe" "observe-only touch

Issue: #$NUM_O
"
RES="$(emit "$REPO" "git commit -m x" "$LANDED_OUT" "" false | IDC_HOOKS_OBSERVE_ONLY=1 python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?
[ "$RC" -eq 0 ] || gov_fail "(O) observer exit was $RC, expected 0"
printf '%s' "$RES" | grep -q '"additionalContext"' || gov_fail "(O) OBSERVE_ONLY must still inject the remediation: $RES"
[ "$(gov_field "$TRK" "$NUM_O" Status)" = "Todo" ] \
  || gov_fail "(O) OBSERVE_ONLY must NOT perform the real repair mutation (Status changed anyway)"
echo "  ok (O) IDC_HOOKS_OBSERVE_ONLY=1 ⇒ no board mutation, injects the remediation instead"

# ── (H) github backend ⇒ local-only reminder naming github coords, ONCE per (session,item) ──────────
REPO_GH="$WORK/repo-gh"; mkdir -p "$REPO_GH/docs/workflow"
printf 'backend: github\n' > "$REPO_GH/docs/workflow/tracker-config.yaml"
git -C "$REPO_GH" init -q
git -C "$REPO_GH" config user.email gov@example.com
git -C "$REPO_GH" config user.name "Governance Test"
git -C "$REPO_GH" checkout -q -B "77-gh-work" >/dev/null 2>&1
date +%s%N > "$REPO_GH/t"; git -C "$REPO_GH" add t >/dev/null; git -C "$REPO_GH" commit -q -m "gh work" >/dev/null
SID="govtest-ghnag-$$"
RES="$(SID="$SID" emit "$REPO_GH" "git commit -m x" "$LANDED_OUT" "" false | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"
printf '%s' "$RES" | grep -q '"additionalContext"' || gov_fail "(H) first github commit should inject a coherence reminder: $RES"
printf '%s' "$RES" | grep -qF -- '--backend github' || gov_fail "(H) github remediation must carry --backend github coords: $RES"
printf '%s' "$RES" | grep -qF "$ENGINE" || gov_fail "(H) github remediation must name the real engine path: $RES"
printf '%s' "$RES" | grep -q '77' || gov_fail "(H) github reminder must reference the branch-linked item #77: $RES"
RES2="$(SID="$SID" emit "$REPO_GH" "git commit -m x" "$LANDED_OUT" "" false | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"
[ -z "$RES2" ] || gov_fail "(H) a SECOND commit for the same (session,item) must be silent (no per-commit nag): $RES2"
echo "  ok (H) github backend ⇒ inject once per (session,item) naming --backend github coords, second commit silent"

# ── (U) undeterminable linkage ⇒ no output ──────────────────────────────────────────────────────────
seed_commit "chore-cleanup" "just a chore, no item reference here"
run "$REPO" "git commit -m x"
[ -z "$RES" ] || gov_fail "(U) an undeterminable linkage must produce NO output: $RES"
echo "  ok (U) commit/branch names no item ⇒ undeterminable linkage, no output"

# ── (F) a commit that did NOT land ⇒ no output ──────────────────────────────────────────────────────
RES="$(emit "$REPO" "git commit -m x" "" "$REJECTED_ERR" false | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?
[ -z "$RES" ] || gov_fail "(F) a rejected git commit (no [branch sha] in output) must produce NO output: $RES"
echo "  ok (F) a commit that did not land ('nothing to commit', no exit_code) ⇒ no output"

# ── (B) a non-commit Bash command ⇒ no output ───────────────────────────────────────────────────────
RES="$(emit "$REPO" "git status" "" "" false | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"
[ -z "$RES" ] || gov_fail "(B) a non-'git commit' Bash command must produce NO output: $RES"
echo "  ok (B) a non-'git commit' Bash command ⇒ self-gated no-op"

# ── (W) a non-Bash tool ⇒ no output ──────────────────────────────────────────────────────────────────
WOUT="$(emit "$REPO" "git commit -m x" "$LANDED_OUT" "" false Write | python3 "$OBS" "$GOV_PLUGIN" 2>"$ERR")"
[ -z "$WOUT" ] || gov_fail "(W) a non-Bash tool must produce NO output: $WOUT"
echo "  ok (W) a non-Bash tool ⇒ self-gated no-op"

# ── (G) non-governed repo ⇒ no output ───────────────────────────────────────────────────────────────
run "$NONGOV" "git commit -m x"
[ -z "$RES" ] || gov_fail "(G) fired outside a governed repo: $RES"
echo "  ok (G) non-governed repo ⇒ repo-gated no-op"

echo "PASS: PostToolUse commit-sync — a drifted item referenced (by trailer or branch number, NOT a bare #N) by a landed commit is auto-repaired to In Progress via the engine (or, when refused, the exact real-path remediation is injected); branch outranks incidental cross-refs; github reminds once per session/item with the right coords; OBSERVE_ONLY suppresses the mutation; coherent items, bare-#N-only/undeterminable linkage, non-landed commits, non-commit commands, non-Bash tools, and non-governed repos are all untouched"
