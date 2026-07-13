#!/usr/bin/env python3
"""idc_command_entry_gate.py — the UserPromptExpansion admission gate (Task 2, command integrity).

Fires when a `/idc:<command>` is about to expand into its body. Before the command runs, this gate:

  1. BINDS the running plugin runtime to the governed repo (Task 1 freshness). A STALE runtime — one
     older than the repo's install receipt or the newest installed plugin — is REFUSED with an
     actionable reload instruction (STALE_REASON). Running a stale command body re-introduces
     just-fixed bugs, so a stale runtime is unsafe for EVERY command, recovery ones included.
  2. On a current runtime + a governed repo, OPENS the command's lifecycle record (command_start) and
     ALLOWS the expansion, injecting the command-contract context so the command body knows it owes a
     `finish` closeout.

FAIL-CLOSED for workflow commands. A governed `think|intake|plan|build|recirculate|autorun` expansion
whose freshness cannot be trusted — an invalid v2 receipt, an unreadable plugin manifest, or ANY
unexpected gate exception — is BLOCKED with a repair message naming `/idc:doctor` and `/idc:update`:
we refuse to run an unverifiable workflow command. RECOVERY / DIAGNOSTIC commands
`doctor|update|uninstall|janitor` (and `init`, which repairs/creates the scaffold) may still expand on
an unknown/invalid legacy receipt so the operator can diagnose or migrate the repo — but they are
STILL blocked on a positively stale runtime, because stale recovery code is itself unsafe. `janitor`
is a recovery/diagnostic sweep ("janitor remains recovery, not the primary guard") — it may run on an
invalid/unknown receipt to help the operator diagnose, and is fail-closed only on a positively stale
runtime, alongside the other recovery commands.

`IDC_HOOKS_OBSERVE_ONLY=1` is the explicit debug-only downgrade: every would-be block becomes a
stderr warning + allow.

Invocation: idc_command_entry_gate.py <PLUGIN_ROOT>   (UserPromptExpansion payload on stdin).
"""
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # scripts/hooks/ — idc_hook_lib, idc_ledger
sys.path.insert(0, os.path.dirname(_HERE))      # scripts/ — idc_plugin_freshness, idc_command_contract
import idc_hook_lib as H  # noqa: E402
import idc_plugin_freshness as freshness  # noqa: E402
import idc_command_contract as C  # noqa: E402

# Fail-closed on an unverifiable freshness signal (invalid receipt / unreadable manifest / gate bug):
# the six workflow commands. Running an unverifiable workflow body can re-introduce just-fixed bugs.
WORKFLOW_COMMANDS = {"think", "intake", "plan", "build", "recirculate", "autorun"}
# May still expand on an unknown/invalid legacy receipt so the operator can diagnose or migrate the
# repo. `janitor` is a recovery/diagnostic sweep (not the primary guard), so it lives here — blocked
# only on a POSITIVELY stale runtime, never on a merely-unverifiable receipt. `init` bootstraps.
ALLOW_ON_INVALID = {"doctor", "update", "uninstall", "janitor", "init"}

STALE_REASON = (
    "IDC refused to expand this command because the active plugin runtime is older than "
    "the governed repo or installed plugin. Run /reload-plugins, then retry the IDC command; "
    "/clear does not reload plugin commands or hooks. A full Claude Code restart is also safe."
)

REPAIR_REASON = (
    "IDC refused to expand this command because it could not verify the plugin runtime against this "
    "repo's install receipt (an invalid or unreadable receipt/manifest). Run /idc:doctor to diagnose "
    "it and /idc:update to re-stamp the repo, then retry the IDC command."
)


def _normalize_command(command_name):
    """Strip one leading slash and accept ONLY `idc:<command>`; return the bare `<command>` (e.g.
    `think`) or None if it is not a namespaced IDC command this gate governs."""
    name = (command_name or "").strip()
    if name.startswith("/"):
        name = name[1:]
    if not name.startswith("idc:"):
        return None
    command = name[len("idc:"):]
    return command if command in C.COMMANDS else None


def _contract_script(plugin_root):
    """The REAL absolute path to idc_command_contract.py under the plugin root the gate was handed.
    `${CLAUDE_PLUGIN_ROOT}` is a markdown-only substitution — it is NOT a shell/Python env var, so a
    Python-emitted literal would resolve to the broken `/scripts/idc_command_contract.py`. The gate
    receives the real root as argv[1] (the hook wrapper passes `${CLAUDE_PLUGIN_ROOT}`); we join that
    actual path so every remediation the gate prints is runnable as-is."""
    return os.path.join(plugin_root or "", "scripts", "idc_command_contract.py")


def _context(command, plugin_root):
    return (
        f"IDC command lifecycle: `/idc:{command}` opened a governed command record. Before this "
        "session stops you MUST close it with a valid terminal status via "
        f"`{_contract_script(plugin_root)} finish --repo <repo> "
        f"--session <session-id> --command {command} --status <complete|waiting_gate|no_action|"
        "blocked_external> --evidence-json '<envelope>'`. The Stop closeout gate will refuse a stop "
        "that leaves this command open."
    )


def _block(reason):
    """Refuse the expansion, honoring the observe-only debug downgrade (warn + allow)."""
    if H.observe_only():
        H.warn(f"OBSERVE-ONLY (would block expansion): {reason}")
        raise SystemExit(0)
    H.prompt_expansion_block(reason)


def _fail_closed_or_allow(command, why, plugin_root):
    """The unverifiable-freshness fork: fail CLOSED for the six workflow commands (block with the
    repair message); ALLOW recovery/diagnostic + init commands (they must run to diagnose or migrate
    the repo)."""
    if command in ALLOW_ON_INVALID:
        H.warn(f"idc-entry-gate: allowing recovery command /idc:{command} despite: {why}")
        H.prompt_expansion_context(_context(command, plugin_root))
    _block(REPAIR_REASON)


def _admit(payload, plugin_root, command):
    cwd = payload.get("cwd") or os.getcwd()
    # Task-1 freshness. An InvalidReceiptError (or any other exception) propagates to the caller's
    # fail-closed handler; here we only decide on a CLEAN evaluation.
    result = freshness.evaluate(plugin_root, repo=cwd)
    if result.running_version is None:
        # The running plugin manifest could not be read → we cannot bind the runtime at all.
        _fail_closed_or_allow(command, "the running plugin manifest could not be read", plugin_root)
    if result.verdict == "stale":
        _block(STALE_REASON)  # blocks EVERY command, recovery ones included (stale code is unsafe)

    # Admitted. On a governed repo, open the lifecycle record (idempotent upsert). `/idc:init` before
    # the repo is governed cannot register yet — init.md opens the record right after it writes
    # tracker-config.yaml (Task 6). A missing session_id likewise skips the write (nothing to key on).
    session_id = payload.get("session_id")
    if session_id and H.is_governed_repo(cwd):
        C.register_start(cwd, session_id, command, result.running_version or "",
                         payload.get("command_args") or "", payload.get("command_source") or "")
    H.prompt_expansion_context(_context(command, plugin_root))


def main():
    plugin_root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    payload = H.read_payload()
    command = _normalize_command(payload.get("command_name"))
    if command is None:
        # Not a namespaced IDC command this gate governs → say nothing, allow the normal flow.
        sys.exit(0)
    try:
        _admit(payload, plugin_root, command)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — an unverifiable gate error is fail-closed for workflow
        _fail_closed_or_allow(command, f"unexpected gate error: {exc}", plugin_root)
    sys.exit(0)


if __name__ == "__main__":
    main()
