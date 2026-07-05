#!/usr/bin/env python3
"""idc_interlock_gate.py — the PreToolUse terminal-action interlocks (v4 Phase 2, plan §3.2).

Fired on PreToolUse for the Bash tool. The transition engine (idc_transition.py) + the finisher tail
(idc_git_finish.py) are the ONE sanctioned door to terminal workflow state — but an agent can still
type a raw `gh pr merge` / `gh issue close` / state-closing `gh api` / raw board mutation
(`gh project item-edit|item-add|item-delete`, GraphQL board field mutations) directly into the Bash
tool, bypassing the door. That is exactly the 394ec6fe "hand-rolled finish / loose improvisation"
class (forensic drops C + D). This gate intercepts those raw commands and points the caller back at
the exact door command.

Rollout posture (§6, decision 1): SHIPS in WARN-INJECT — it surfaces the remediation but does NOT
block, so a fresh install can never brick a real workflow. A promotion switch
(IDC_HOOKS_INTERLOCK_ENFORCE=1) turns it into a hard deny (permissionDecision=deny, self-healing
remediation); IDC_HOOKS_OBSERVE_ONLY=1 universally downgrades any deny back to warn (the operator
debug escape). Hard-deny promotion is a later operator decision — the deny path exists + is
e2e-exercised via the switch now.

Why this NEVER fires on the sanctioned path: the engine + finisher run `gh` via python subprocess,
NOT via the Bash tool, so PreToolUse never sees them; and a `python3 …/idc_git_finish.py …` Bash call
does not match any pattern here. Only a RAW terminal command typed into Bash matches. The gate is a
pure command-string classifier — no board reads, no GraphQL, zero added latency budget.

Invocation: idc_interlock_gate.py <PLUGIN_ROOT>   (PreToolUse payload on stdin).
Self-gated: no-op (allow) outside a governed repo, for non-Bash tools, or on a non-matching command.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402

# ── remediations (every message names the EXACT door command, per P3 self-healing) ────────────────
_FINISH = (
    "run the receipt-gated finisher tail instead: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py --pr <N> --issue <M> "
    "--worktree <path> --verdict <verdict.json>` — it validates the review receipt, merges, and "
    "closes the tracker item through the single write door."
)
_CLOSE = (
    "the finisher closes the tracker item as part of `idc_git_finish.py` (above), or use the "
    "transition engine's guarded close directly: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo <repo> close <issue> "
    "--pr <N> --verdict <verdict.json>`."
)
_ENGINE = (
    "route it through the single write door: "
    "`python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_transition.py --repo <repo> <op> …` "
    "(create-ticket | create-pointer | claim | move | close | retire | recirculate-intake | "
    "link | unblock) — never mutate the board with a raw `gh project`/GraphQL call."
)

# Classifier rules, checked in order. Each: (matcher(command)->bool, subject, remediation).
# `_has(*parts)` → the command contains every part (whitespace-flexible) — so `gh   pr   merge` and
# `cd x && gh pr merge --squash` both match, while `gh pr view` / `gh project item-list` do not.
_WS = r"\s+"


def _has(command, *word_seqs):
    """True iff `command` contains a run of whitespace-separated words for EVERY seq in `word_seqs`."""
    for seq in word_seqs:
        pat = _WS.join(re.escape(w) for w in seq.split())
        if not re.search(r"(?<![\w-])" + pat + r"(?![\w-])", command):
            return False
    return True


def classify(command):
    """(subject, remediation) for a raw terminal/board command that bypasses the door, or None."""
    c = command
    # state-closing gh api (REST `-f/-F state=closed` or a raw `state=closed`) — a hand issue close.
    if _has(c, "gh api") and re.search(r"state\s*[=:]\s*[\"']?closed", c):
        return ("a state-closing `gh api` call", _CLOSE)
    # GraphQL board mutations (field value / add / delete) — raw board writes.
    if _has(c, "gh api") and re.search(r"updateProjectV2ItemFieldValue|addProjectV2ItemById|"
                                       r"deleteProjectV2Item|closeIssue", c):
        return ("a raw GraphQL board mutation", _ENGINE)
    if _has(c, "gh pr merge"):
        return ("a raw `gh pr merge`", _FINISH)
    if _has(c, "gh issue close"):
        return ("a raw `gh issue close`", _CLOSE)
    if _has(c, "gh project item-edit") or _has(c, "gh project item-add") \
            or _has(c, "gh project item-delete"):
        return ("a raw `gh project item-{edit,add,delete}` board mutation", _ENGINE)
    return None


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    if not H.is_governed_repo(cwd):
        H.pre_tool_allow()
    if payload.get("tool_name") != "Bash":
        H.pre_tool_allow()
    command = (payload.get("tool_input") or {}).get("command")
    if not isinstance(command, str) or not command.strip():
        H.pre_tool_allow()

    hit = classify(command)
    if not hit:
        H.pre_tool_allow()
    subject, remediation = hit
    reason = (
        f"IDC interlock: {subject} bypasses the single write door (the 394ec6fe hand-rolled-finish / "
        f"loose-improvisation class). Do not run it by hand — {remediation}"
    )
    if os.environ.get("IDC_HOOKS_INTERLOCK_ENFORCE", "") == "1":
        H.pre_tool_deny(reason)   # promoted posture (honors OBSERVE_ONLY → warn)
    H.pre_tool_warn(reason)       # shipped posture: warn-inject, never blocks


if __name__ == "__main__":
    H.guard_pre_tool(_gate)
