#!/bin/bash
# idc_interlock_gate_hook.sh — the PreToolUse wrapper for the shared Path Gate transport.
#
# Registered by hooks/hooks.json as a PreToolUse command hook for Bash/Write/Edit. Claude Code runs
# it with the working directory set to the session repo and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the
# markdown token is NOT a shell env var inside a hook — the plugin root must arrive as an argument,
# per CLAUDE.md).
#
# Contract (mirrors the SubagentStop verdict-gate wrapper):
#   * FAST NO-OP (exit 0) when docs/workflow/tracker-config.yaml is absent in cwd — not an
#     IDC-governed repo, so we never spawn python. (The gate ALSO repo-gates on the payload's cwd.)
#   * Otherwise exec the gate, forwarding the PreToolUse payload on stdin. The gate self-gates to the
#     supported mutation tools (Bash/Write/Edit) and decides allow (exit 0, no output) or deny
#     (permissionDecision JSON; downgraded to stderr warning only under IDC_HOOKS_OBSERVE_ONLY=1).
#   * FAIL-SOFT: a missing plugin root / gate script → exit 0 (allow). The gate's own P4 fail mode
#     (idc_hook_lib.guard_pre_tool) handles internal errors (fail-open unless IDC_HOOKS_STRICT=1).
#   * FAIL-CLOSED ON AN UNUSABLE RUNTIME (F57): see the block at the bottom of this file. An
#     unsupported/missing python3 means the gate CANNOT run, and this wrapper — not the gate —
#     decides. It never allows silently.
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to gate (fast path: never spawn python).
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_interlock_gate.py" ] || exit 0

# --- unusable runtime: refuse, never a silent allow (F57) -----------------------------------------
#
# The gate needs Python >= 3.10 (it uses `X | Y` annotations that raise on import under 3.9). This
# branch used to be `sh idc_python_runtime.sh || exit 0` — exit 0 = ALLOW — reached AFTER the repo
# was confirmed governed and BEFORE the pathway mode was ever read. On any host whose python3
# predates 3.10 (a reduced-PATH agent pane and stock macOS both qualify) the ENTIRE shared Path Gate
# silently permitted every Bash/Write/Edit/NotebookEdit mutation in `app-locked` mode, emitting zero
# output. That is the exact opposite of what this plugin's own git hooks do for the identical
# condition (idc_git_pre_commit.sh / idc_git_pre_push.sh both `exit 1`).
#
# The refusal is POSTURE-AWARE rather than blanket, because a blanket deny would brick ordinary work
# in every `off`-mode repo (the filesystem-backend default) on an old interpreter — a bigger outage
# than the hole it closes. The posture is read by the SHIPPED parser through a probe written to run
# on old interpreters (scripts/idc_pathway_posture_probe.py), never by a second config parser here.
#
#   off                      -> allow, but LOUDLY: the contract for `off` is observe-and-allow, and
#                               a silent allow is what F57 was about.
#   controlled | app-locked  -> hard deny. Their published contract IS hard-deny; the gate cannot
#                               evaluate authorization, so the fail-closed answer is the honest one.
#   unknown                  -> hard deny. The posture could not be established, and "cannot tell"
#                               is never evidence of a non-enforcing repo (mirrors the F10 rule that
#                               a declared-but-unrecognized mode fails closed).
#
# IDC_HOOKS_OBSERVE_ONLY=1 downgrades the deny to the same loud warning in every mode — the same
# documented debug escape idc_hook_lib.pre_tool_deny honors, and the operator's way out of a repo
# whose interpreter is too old to fix from inside a denied Bash call.
if ! sh "$ROOT/scripts/idc_python_runtime.sh"; then
  RUNTIME_FIX="IDC requires Python 3.10 or newer to evaluate mutations; python3 is missing or older. Install or select a supported python3 (see /idc:doctor row 8), or set IDC_HOOKS_OBSERVE_ONLY=1 to downgrade this repo's Path Gate to observe."
  POSTURE="$(python3 "$ROOT/scripts/idc_pathway_posture_probe.py" "$PWD" 2>/dev/null)" || POSTURE=""
  [ -n "$POSTURE" ] || POSTURE="unknown"
  if [ "${IDC_HOOKS_OBSERVE_ONLY:-}" = "1" ] || [ "$POSTURE" = "off" ]; then
    echo "IDC Path Gate: NOT ENFORCING (pathway mode $POSTURE) — $RUNTIME_FIX" >&2
    exit 0
  fi
  printf '%s\n' "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"IDC Path Gate denied this mutation because it cannot be evaluated in pathway mode $POSTURE: $RUNTIME_FIX\"}}"
  exit 0
fi

exec python3 "$ROOT/scripts/hooks/idc_interlock_gate.py" "$ROOT"
