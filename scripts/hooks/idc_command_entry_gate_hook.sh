#!/bin/bash
# idc_command_entry_gate_hook.sh — the UserPromptExpansion wrapper for the command entry gate
# (Task 2, command integrity).
#
# Registered by hooks/hooks.json with the matcher `^idc:(autorun|build|doctor|init|intake|janitor|
# plan|recirculate|think|uninstall|update)$`, so it fires ONLY for a governed `/idc:*` command
# expansion. Claude Code runs it with the working directory set to the session repo and passes
# ${CLAUDE_PLUGIN_ROOT} as $1 (the markdown token is NOT a shell env var inside a hook — the plugin
# root must arrive as an argument, per CLAUDE.md).
#
# Contract:
#   * Unlike the Stop/SubagentStop wrappers, this one does NOT fast-skip a non-governed repo: the
#     gate must run its freshness check even before the repo is governed (e.g. `/idc:init`), and the
#     matcher already scopes it to IDC commands only.
#   * Otherwise exec the gate, forwarding the UserPromptExpansion payload on stdin. The gate decides
#     allow-with-context ({"additionalContext": ...}) vs block ({"decision":"block", ...}).
#   * FAIL-SOFT at the WRAPPER layer: a missing plugin root / gate script → exit 0 (allow). The gate's
#     own fail mode (fail-closed for workflow commands on an unverifiable runtime) handles the rest.
set -u

ROOT="${1:-}"

# Plugin root unknown (shouldn't happen via hooks.json) or gate missing → fail-soft allow.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_command_entry_gate.py" ] || exit 0

if ! sh "$ROOT/scripts/idc_python_runtime.sh"; then
  printf '%s\n' '{"decision":"block","reason":"IDC requires Python 3.10 or newer. Install or select a supported python3, then retry the command."}'
  exit 0
fi

exec python3 "$ROOT/scripts/hooks/idc_command_entry_gate.py" "$ROOT"
