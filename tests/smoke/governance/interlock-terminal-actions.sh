#!/bin/bash
# interlock-terminal-actions.sh — governance scenario: the PreToolUse interlocks (v4 Phase 2, §3.2).
#
# The invariant: a RAW terminal/board command typed into the Bash tool — `gh pr merge`,
# `gh issue close`, a state-closing `gh api`, a raw board mutation (`gh project item-edit|item-add|
# item-delete`, a GraphQL board write) — bypasses the single write door (idc_transition.py /
# idc_git_finish.py). The interlock gate intercepts it and names the exact door command. It SHIPS in
# warn-inject (surface the remediation, never block — a fresh install can't brick a workflow); a
# promotion switch (IDC_HOOKS_INTERLOCK_ENFORCE=1) makes it a hard deny; IDC_HOOKS_OBSERVE_ONLY=1
# downgrades any deny back to warn. It NEVER fires on the sanctioned path (the finisher's own python
# call), on a read (`gh pr view` / `gh project item-list`), on a non-Bash tool, or outside a
# governed repo.
#
# Red-when-broken: neuter idc_interlock_gate.classify (make it always return None) → the (W)/(D)/(B)/
# (C) fire-cases all stop firing → this scenario FAILs.
#
#   (W) raw `gh pr merge` ⇒ WARN-INJECT naming idc_git_finish.py, exit 0, NO deny on stdout [headline]
#   (D) same, IDC_HOOKS_INTERLOCK_ENFORCE=1 ⇒ hard DENY (permissionDecision=deny) naming idc_git_finish.py
#   (O) same + IDC_HOOKS_OBSERVE_ONLY=1 ⇒ downgraded to warn (no deny on stdout)
#   (B) raw `gh project item-edit` ⇒ interlock fires naming idc_transition.py
#   (C) state-closing `gh api … -f state=closed` ⇒ interlock fires (close remediation)
#   (A) allow: `gh pr view` / `gh project item-list` / the finisher's own python call ⇒ NO output
#   (T) a non-Bash tool ⇒ NO output (self-gated)
#   (G) non-governed repo ⇒ NO output (repo-gated)
#
# Usage: bash tests/smoke/governance/interlock-terminal-actions.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE (not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
NONGOV="$WORK/plain"; mkdir -p "$NONGOV"   # no docs/workflow/tracker-config.yaml

# emit a PreToolUse payload JSON (cwd + tool + command) with python so command quoting is exact.
emit() { CWD="$1" TOOL="$2" CMD="$3" python3 -c \
  'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]}}))'; }

ERR="$WORK/err"
# gate <cwd> <tool> <command>  → runs the gate; sets $OUT (stdout) + writes stderr to $ERR + $RC.
# Env prefixes (IDC_HOOKS_*) set by the caller propagate to the gate + its children.
gate() { OUT="$(emit "$1" "$2" "$3" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

MERGE="cd wt && gh pr merge 12 --squash --delete-branch"

# ── (W) warn-inject by default (headline) ──────────────────────────────────────────────────────────
gate "$REPO" Bash "$MERGE"
[ "$RC" -eq 0 ] || gov_fail "(W) gate exit was $RC, expected 0 (warn-inject never blocks)"
[ -z "$OUT" ] || gov_fail "(W) warn-inject must NOT emit a permission decision on stdout: $OUT"
grep -q 'IDC interlock' "$ERR" || gov_fail "(W) no interlock warning on stderr: $(cat "$ERR")"
grep -q 'idc_git_finish.py' "$ERR" || gov_fail "(W) warning did not name the idc_git_finish.py remediation: $(cat "$ERR")"
echo "  ok (W) raw gh pr merge ⇒ warn-inject naming idc_git_finish.py, never blocks [headline]"

# ── (D) hard deny under the promotion switch ────────────────────────────────────────────────────────
IDC_HOOKS_INTERLOCK_ENFORCE=1 gate "$REPO" Bash "$MERGE"
[ "$RC" -eq 0 ] || gov_fail "(D) gate exit was $RC, expected 0 (a hook signals via JSON, not exit code)"
printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"' \
  || gov_fail "(D) IDC_HOOKS_INTERLOCK_ENFORCE=1 did not hard-deny: $OUT"
printf '%s' "$OUT" | grep -q 'idc_git_finish.py' \
  || gov_fail "(D) deny reason did not name the idc_git_finish.py remediation: $OUT"
echo "  ok (D) IDC_HOOKS_INTERLOCK_ENFORCE=1 ⇒ hard deny naming idc_git_finish.py"

# ── (O) OBSERVE_ONLY downgrades the deny back to warn ───────────────────────────────────────────────
IDC_HOOKS_INTERLOCK_ENFORCE=1 IDC_HOOKS_OBSERVE_ONLY=1 gate "$REPO" Bash "$MERGE"
[ -z "$OUT" ] || gov_fail "(O) OBSERVE_ONLY must downgrade deny → no stdout decision: $OUT"
grep -qi 'would deny' "$ERR" || gov_fail "(O) OBSERVE_ONLY did not warn-downgrade the deny: $(cat "$ERR")"
echo "  ok (O) IDC_HOOKS_OBSERVE_ONLY=1 downgrades the deny to a warning"

# ── (B) raw board mutation ⇒ interlock fires naming the engine ──────────────────────────────────────
gate "$REPO" Bash "gh project item-edit --id ITEM --project-id PVT_x --field-id F --single-select-option-id O"
grep -q 'IDC interlock' "$ERR" || gov_fail "(B) raw gh project item-edit did not fire the interlock: $(cat "$ERR")"
grep -q 'idc_transition.py' "$ERR" || gov_fail "(B) board-mutation warning did not name idc_transition.py: $(cat "$ERR")"
echo "  ok (B) raw gh project item-edit ⇒ interlock fires naming idc_transition.py"

# ── (C) state-closing gh api ⇒ interlock fires (REST field form AND JSON-body form) ─────────────────
gate "$REPO" Bash 'gh api repos/o/r/issues/5 -X PATCH -f state=closed'
grep -q 'IDC interlock' "$ERR" || gov_fail "(C) state-closing gh api (-f state=closed) did not fire: $(cat "$ERR")"
gate "$REPO" Bash 'gh api repos/o/r/issues/5 -X PATCH --input - <<< '\''{"state":"closed"}'\'''
grep -q 'IDC interlock' "$ERR" || gov_fail "(C) state-closing gh api (JSON body \"state\":\"closed\") did not fire: $(cat "$ERR")"
echo "  ok (C) state-closing gh api (REST -f state=closed AND JSON body) ⇒ interlock fires (close remediation)"

# ── (A) allow the sanctioned path + reads (no false positives) ──────────────────────────────────────
allow_case() {  # $1 = command that must NOT fire the interlock
  gate "$REPO" Bash "$1"
  [ "$RC" -eq 0 ] || gov_fail "(A) exit $RC on an allowed command: $1"
  [ -z "$OUT" ] || gov_fail "(A) emitted a decision for an allowed command ($1): $OUT"
  grep -q 'IDC interlock' "$ERR" && gov_fail "(A) wrongly fired the interlock on: $1  ⇒ $(cat "$ERR")"
  return 0
}
allow_case 'python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py --pr 12 --issue 3 --worktree wt --verdict v.json'
allow_case 'gh pr view 12 --json state,mergeable'
allow_case 'gh project item-list 8 --owner me --limit 100'
allow_case 'gh issue view 5 --json state'
echo "  ok (A) the finisher's own call + gh reads (pr view / project item-list / issue view) ⇒ no false positive"

# ── (T) a non-Bash tool ⇒ self-gated no-op ──────────────────────────────────────────────────────────
gate "$REPO" Write "$MERGE"
[ -z "$OUT" ] || gov_fail "(T) fired for a non-Bash tool: $OUT"
grep -q 'IDC interlock' "$ERR" && gov_fail "(T) fired for a non-Bash tool: $(cat "$ERR")"
echo "  ok (T) a non-Bash tool ⇒ self-gated no-op"

# ── (G) non-governed repo ⇒ repo-gated no-op ────────────────────────────────────────────────────────
gate "$NONGOV" Bash "$MERGE"
[ -z "$OUT" ] || gov_fail "(G) fired outside a governed repo: $OUT"
grep -q 'IDC interlock' "$ERR" && gov_fail "(G) fired outside a governed repo: $(cat "$ERR")"
echo "  ok (G) non-governed repo ⇒ repo-gated no-op"

echo "PASS: PreToolUse interlocks — a raw gh pr merge / gh issue close / state-closing gh api / raw board mutation warn-injects the exact door command (deny-capable via IDC_HOOKS_INTERLOCK_ENFORCE=1; OBSERVE_ONLY downgrades); the sanctioned finisher call, reads, non-Bash tools, and non-governed repos are untouched"
