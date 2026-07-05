#!/bin/bash
# idc_post_commit_sync_hook.sh — the PostToolUse wrapper for the commit-sync board-coherence
# observer (v4 Phase 3 Stage D).
#
# Registered by hooks/hooks.json as a PostToolUse command hook with a Bash matcher. Claude Code runs
# it with the working directory set to the session repo and passes ${CLAUDE_PLUGIN_ROOT} as $1 (the
# markdown token is NOT a shell env var inside a hook — the plugin root must arrive as an argument,
# per CLAUDE.md).
#
# Contract (mirrors the PreToolUse interlock wrapper):
#   * FAST NO-OP (exit 0) when docs/workflow/tracker-config.yaml is absent in cwd — not an
#     IDC-governed repo, so we never spawn python. (The observer ALSO repo-gates on the payload's cwd.)
#   * Otherwise exec the observer, forwarding the PostToolUse payload on stdin. It self-gates to the
#     Bash tool + a successful `git commit` + a resolvable linked item, then auto-repairs or injects.
#   * FAIL-SOFT, ALWAYS: a missing plugin root / observer script → exit 0 (nothing injected). The
#     observer's own P4 fail mode (idc_hook_lib.guard_post_observer) handles internal errors
#     (fail-open unconditionally — a post-hoc observer must NEVER break the command that already ran).
set -u

ROOT="${1:-}"

# Not an IDC-governed repo → nothing to observe (fast path: never spawn python).
[ -f "docs/workflow/tracker-config.yaml" ] || exit 0

# Plugin root unknown (shouldn't happen via hooks.json) or observer missing → fail-soft, no output.
[ -n "$ROOT" ] && [ -f "$ROOT/scripts/hooks/idc_post_commit_sync.py" ] || exit 0

# Cheap pre-filter: the matcher is every Bash call, but only a `git commit` is relevant. Skip spawning
# python for the ~all Bash calls that don't mention "commit" ("commit" is a single token, immune to the
# whitespace-flexible `git   commit` forms the observer itself still matches precisely). Behaviour-
# preserving: the observer re-checks the command precisely, so this only trims wasted process spawns.
PAYLOAD="$(cat)"
printf '%s' "$PAYLOAD" | grep -qF 'commit' || exit 0

printf '%s' "$PAYLOAD" | python3 "$ROOT/scripts/hooks/idc_post_commit_sync.py" "$ROOT"
