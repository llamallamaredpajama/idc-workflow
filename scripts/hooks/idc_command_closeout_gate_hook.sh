#!/bin/bash
# idc_command_closeout_gate_hook.sh — the Stop wrapper for the command-closeout gate (Task 2,
# command integrity).
#
# Registered by hooks/hooks.json as a SECOND matcher-less Stop command hook (alongside the fixpoint
# gate); it fires for EVERY main-session stop on the machine, so it self-gates fast. Claude Code runs
# it with the working directory set to the session repo and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the
# markdown token is NOT a shell env var inside a hook — the plugin root must arrive as an argument,
# per CLAUDE.md).
#
# Contract (mirrors the Stop fixpoint-gate wrapper):
#   * FAST NO-OP (exit 0) when docs/workflow/tracker-config.yaml is absent in cwd — not an
#     IDC-governed repo, so we never spawn python. (The gate ALSO repo-gates on the payload's cwd.)
#   * Otherwise exec the gate, forwarding the Stop payload on stdin. The gate self-selects to sessions
#     that hold an OPEN command record and decides allow (exit 0, no output) vs block
#     ({"decision":"block", ...}), bounded N=3 then loud-fail.
#   * FAIL-SOFT at the WRAPPER layer: a missing plugin root / gate script → exit 0 (allow). The gate's
#     own split fail mode (allow before a record is found, fail-closed after) handles internal errors.
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to gate (fast path: never spawn python).
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_command_closeout_gate.py" ] || exit 0
sh "$ROOT/scripts/idc_python_runtime.sh" || exit 0

exec python3 "$ROOT/scripts/hooks/idc_command_closeout_gate.py" "$ROOT"
