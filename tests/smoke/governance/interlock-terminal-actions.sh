#!/bin/bash
# interlock-terminal-actions.sh — governance scenario: the PreToolUse interlocks (v4 Phase 2, §3.2).
#
# The invariant: a RAW terminal/board command typed into the Bash tool — `gh pr merge`,
# `gh issue close`, a state-closing `gh api`, a raw board mutation (`gh project item-edit|item-add|
# item-delete`, a GraphQL board write) — bypasses the single write door (idc_transition.py /
# idc_git_finish.py). The interlock gate intercepts it and names the exact door command.
#
# POSTURE (U4 shared Path Gate): every raw governed mutation is a HARD DENY unless it comes through
# the sanctioned door with a live authorization. Classifier-only/warn-only behavior is no longer a
# valid safety posture: a raw `gh pr merge` / `gh issue close` / board mutation / issue-state write
# must be denied even when NO active lifecycle record exists. IDC_HOOKS_OBSERVE_ONLY=1 is still the
# one debug escape hatch that downgrades any deny back to a warning. The gate NEVER fires on the
# sanctioned path (the finisher's own python call), on a read (`gh pr view` / `gh project item-list`),
# on a non-Bash tool, or outside a governed repo. (Indirection-aware inspection is covered by the
# sibling interlock-script-indirection.sh.)
#
# Red-when-broken: neuter idc_interlock_gate.classify (make it always return None) → the (N)/(D)/(B)/
# (C) fire-cases all stop firing → this scenario FAILs.
#
#   (N) raw `gh pr merge`, NO active command ⇒ hard DENY naming idc_git_finish.py [headline]
#   (D) same, an ACTIVE /idc:* command owned by the payload's session ⇒ hard DENY naming idc_git_finish.py
#   (O) same active command + IDC_HOOKS_OBSERVE_ONLY=1 ⇒ warning/additionalContext, never a deny
#   (B) raw `gh project item-edit` (no active command) ⇒ hard DENY naming idc_transition.py
#   (C) state-closing `gh api … -f state=closed` (no active command) ⇒ hard DENY (close remediation)
#   (A) allow: `gh pr view` / `gh project item-list` / the finisher's own python call ⇒ NO output
#   (T) a non-Bash tool ⇒ NO output (self-gated)
#   (G) non-governed repo ⇒ NO output (repo-gated)
#
# Usage: bash tests/smoke/governance/interlock-terminal-actions.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib.sh"

GATE="$GOV_PLUGIN/scripts/hooks/idc_interlock_gate.py"
CONTRACT="$GOV_PLUGIN/scripts/idc_command_contract.py"
[ -f "$GATE" ] || gov_fail "idc_interlock_gate.py not found at $GATE (not implemented yet)"
[ -f "$CONTRACT" ] || gov_fail "idc_command_contract.py not found at $CONTRACT (not implemented yet)"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"; mkdir -p "$REPO/docs/workflow"
printf 'backend: filesystem\n' > "$REPO/docs/workflow/tracker-config.yaml"
printf 'pathway_enforcement:\n  mode: controlled\n' > "$REPO/WORKFLOW-config.yaml"
printf '# tracker state for build-lane command_start\n' > "$REPO/TRACKER.md"
NONGOV="$WORK/plain"; mkdir -p "$NONGOV"   # no docs/workflow/tracker-config.yaml

# SD owns an ACTIVE /idc:* command; SW owns nothing (per-run-unique, like the sibling lifecycle test).
SD="sd-$$-$(basename "$WORK")"
SW="sw-$$-$(basename "$WORK")"
python3 "$CONTRACT" start --repo "$REPO" --session "$SD" --command build \
  --plugin-root "$GOV_PLUGIN" --args 'x' --source user >/dev/null \
  || gov_fail "could not open the active /idc:build command record for $SD"

# emit a PreToolUse payload JSON (cwd + tool + command + session) with python so quoting is exact.
emit() { CWD="$1" TOOL="$2" CMD="$3" SID="$4" python3 -c \
  'import os,json;print(json.dumps({"cwd":os.environ["CWD"],"tool_name":os.environ["TOOL"],"tool_input":{"command":os.environ["CMD"]},"session_id":os.environ["SID"]}))'; }

ERR="$WORK/err"
# gate <cwd> <tool> <command> <session>  → runs the gate; sets $OUT (stdout) + stderr $ERR + $RC.
# Env prefixes (IDC_HOOKS_*) set by the caller propagate to the gate + its children.
gate() { OUT="$(emit "$1" "$2" "$3" "$4" | python3 "$GATE" "$GOV_PLUGIN" 2>"$ERR")"; RC=$?; }

MERGE="cd wt && gh pr merge 12 --squash --delete-branch"

is_deny() { printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"'; }

# ── (N) hard deny even when NO active command owns the session (headline) ─────────────────────────
gate "$REPO" Bash "$MERGE" "$SW"
[ "$RC" -eq 0 ] || gov_fail "(N) gate exit was $RC, expected 0 (a hook signals via JSON, not exit code)"
is_deny || gov_fail "(N) a raw merge without a live authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
printf '%s' "$OUT" | grep -q 'idc_git_finish.py' \
  || gov_fail "(N) deny reason did not name the idc_git_finish.py remediation: $OUT"
echo "  ok (N) raw gh pr merge, no active command ⇒ hard deny naming idc_git_finish.py [headline]"

# ── (D) hard deny while the session owns an active /idc:* command ─────────────────────────────────────
gate "$REPO" Bash "$MERGE" "$SD"
[ "$RC" -eq 0 ] || gov_fail "(D) gate exit was $RC, expected 0 (a hook signals via JSON, not exit code)"
printf '%s' "$OUT" | grep -q '"permissionDecision": *"deny"' \
  || gov_fail "(D) an active command did not hard-deny the raw merge: $OUT"
printf '%s' "$OUT" | grep -q 'idc_git_finish.py' \
  || gov_fail "(D) deny reason did not name the idc_git_finish.py remediation: $OUT"
echo "  ok (D) active /idc:* command ⇒ hard deny naming idc_git_finish.py"

# ── (O) OBSERVE_ONLY downgrades the active-command deny back to warn ─────────────────────────────────
IDC_HOOKS_OBSERVE_ONLY=1 gate "$REPO" Bash "$MERGE" "$SD"
[ "$RC" -eq 0 ] || gov_fail "(O) OBSERVE_ONLY gate exit was $RC, expected 0"
! is_deny || gov_fail "(O) OBSERVE_ONLY must never emit permissionDecision=deny: $OUT"
printf '%s' "$OUT" | grep -q '"additionalContext"' \
  || gov_fail "(O) OBSERVE_ONLY did not inject the would-be denial as additionalContext: $OUT"
printf '%s' "$OUT" | grep -qi 'observe' \
  || gov_fail "(O) OBSERVE_ONLY additionalContext did not identify the observe posture: $OUT"
grep -qi 'would deny' "$ERR" || gov_fail "(O) OBSERVE_ONLY did not warn-downgrade the deny: $(cat "$ERR")"
echo "  ok (O) IDC_HOOKS_OBSERVE_ONLY=1 downgrades the active-command deny to warning + additionalContext"

# ── (B) raw board mutation ⇒ interlock fires naming the engine ──────────────────────────────────────
gate "$REPO" Bash "gh project item-edit --id ITEM --project-id PVT_x --field-id F --single-select-option-id O" "$SW"
is_deny || gov_fail "(B) raw gh project item-edit without a live authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
printf '%s' "$OUT" | grep -q 'idc_transition.py' || gov_fail "(B) board-mutation deny did not name idc_transition.py: $OUT"
# The remediation must name the CURRENT engine op set: the #150 `dispose` terminal-disposition door
# is present, and the REMOVED `retire` op is gone (else the suggested self-healing recovery command
# would be rejected by the engine's argparse). Red-when-broken: revert the op list to name `retire`.
printf '%s' "$OUT" | grep -q 'dispose' || gov_fail "(B) board-mutation remediation must name the dispose op (the #150 terminal-disposition door)"
printf '%s' "$OUT" | grep -qw 'retire' && gov_fail "(B) board-mutation remediation still names the removed retire engine op (its argparse-invalid recovery defeats the interlock self-heal)"
echo "  ok (B) raw gh project item-edit ⇒ hard deny naming idc_transition.py (op list = current, dispose present, retire gone)"

# ── (C) state-closing gh api ⇒ interlock fires (REST field form AND JSON-body form) ─────────────────
gate "$REPO" Bash 'gh api repos/o/r/issues/5 -X PATCH -f state=closed' "$SW"
is_deny || gov_fail "(C) state-closing gh api (-f state=closed) without a live authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
gate "$REPO" Bash 'gh api repos/o/r/issues/5 -X PATCH --input - <<< '\''{"state":"closed"}'\''' "$SW"
is_deny || gov_fail "(C) state-closing gh api (JSON body \"state\":\"closed\") without a live authorization was not denied: stdout=[$OUT] stderr=[$(cat "$ERR")]"
echo "  ok (C) state-closing gh api (REST -f state=closed AND JSON body) ⇒ hard deny (close remediation)"

# ── (A) allow the sanctioned path + reads (no false positives) ──────────────────────────────────────
allow_case() {  # $1 = command that must NOT fire the interlock (even while a command is active: SD)
  gate "$REPO" Bash "$1" "$SD"
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
gate "$REPO" Write "$MERGE" "$SD"
[ -z "$OUT" ] || gov_fail "(T) fired for a non-Bash tool: $OUT"
grep -q 'IDC interlock' "$ERR" && gov_fail "(T) fired for a non-Bash tool: $(cat "$ERR")"
echo "  ok (T) a non-Bash tool ⇒ self-gated no-op"

# ── (G) non-governed repo ⇒ repo-gated no-op ────────────────────────────────────────────────────────
gate "$NONGOV" Bash "$MERGE" "$SD"
[ -z "$OUT" ] || gov_fail "(G) fired outside a governed repo: $OUT"
grep -q 'IDC interlock' "$ERR" && gov_fail "(G) fired outside a governed repo: $(cat "$ERR")"
echo "  ok (G) non-governed repo ⇒ repo-gated no-op"

echo "PASS: PreToolUse interlocks — a raw gh pr merge / gh issue close / state-closing gh api / raw board mutation hard-denies both without a live authorization and during an active /idc:* command (OBSERVE_ONLY downgrades any deny); the sanctioned finisher call, reads, non-Bash tools, and non-governed repos are untouched"
