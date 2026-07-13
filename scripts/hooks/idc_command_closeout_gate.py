#!/usr/bin/env python3
"""idc_command_closeout_gate.py — the Stop command-closeout gate (Task 2, command integrity).

Fired on `Stop` (the main session's stop). It closes the "walked away from an open command" failure:
a session that ENTERED a governed `/idc:*` command (a lifecycle record was opened at expansion) but
never CLOSED it with a valid terminal status. The gate self-selects by the session's OWN active
command records and refuses the stop until the command is closed via `idc_command_contract.py finish`.

SELF-SELECT + SPARE THE UNRELATED. `active_commands(cwd, session_id)` is session-scoped: it returns
ONLY this session's active command records. A session with none (an ordinary non-IDC session, or one
whose commands all closed honestly) is allowed instantly. It never clears the record itself — the ONE
honest way out is a real `finish`.

FAIL MODE (deliberately NOT a generic post-hoc observer). BEFORE any active record is found — including
if the ledger read itself errors — the gate ALLOWS: an ordinary non-IDC session must never be trapped
by a gate bug. AFTER an active record has been found, an exception is a BOUNDED fail-closed Stop: the
gate cannot prove the command closed honestly, so it blocks (bounded N=3, then loud-fail-allow — never
an infinite nag; Claude Code's `stop_hook_active` is the second backstop). `IDC_HOOKS_OBSERVE_ONLY=1`
downgrades the block to a warning. Repo-gated: an instant no-op outside an IDC-governed repo.

Invocation: idc_command_closeout_gate.py <PLUGIN_ROOT>   (Stop payload on stdin).
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402
import idc_ledger  # noqa: E402


def _block_reason(session_id, command):
    return (
        f"IDC command closeout gate: the '/idc:{command}' command opened in this session has no "
        "recorded closeout, so this stop cannot prove the command finished honestly. Close it with "
        "its terminal status via "
        f"`${{CLAUDE_PLUGIN_ROOT}}/scripts/idc_command_contract.py finish --repo <repo> "
        f"--session {session_id} --command {command} "
        "--status <complete|waiting_gate|no_action|blocked_external> --evidence-json '<envelope>'`, "
        "then stop. (Bounded — this will not block indefinitely.)"
    )


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id")

    # Repo-gate + attribution: instant no-op outside a governed repo, or when the stop is not
    # attributable to a session (nothing to key an active record on).
    if not H.is_governed_repo(cwd):
        H.allow()
    if not session_id:
        H.allow()

    # BEFORE any record is found — a read error here fails OPEN (never trap a non-IDC session).
    try:
        active = idc_ledger.active_commands(cwd, session_id)
    except Exception as exc:  # noqa: BLE001 — pre-classification failure is an allow
        H.warn(f"command-closeout: could not read active commands, allowing: {exc}")
        H.allow()

    if not active:
        H.allow()

    # AFTER an active record is found — this session OWES an honest closeout. From here an exception is
    # a BOUNDED fail-closed stop (we cannot prove the command closed). Pick the lowest-sorted command
    # for a stable per-command anti-nag key when several are open.
    command = sorted(str(c.get("command")) for c in active)[0]
    key = f"command-closeout.{session_id}.{command}"
    try:
        H.bounded_block(key, _block_reason(session_id, command))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — an error AFTER a record was found is fail-closed
        H.bounded_block(
            key,
            "IDC command closeout gate: an open command record exists for this session but its "
            f"state could not be verified ({exc}). Failing closed — close the command via "
            "`${CLAUDE_PLUGIN_ROOT}/scripts/idc_command_contract.py finish ...`, then stop.")


if __name__ == "__main__":
    # NOT guard_pre_action: that fails OPEN on ANY exception, but this gate must fail CLOSED once an
    # active command record has been found. The gate implements its own split fail mode (see docstring).
    _plugin_root = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("CLAUDE_PLUGIN_ROOT", "")
    _payload = H.read_payload()
    _gate(_payload, _plugin_root)
    sys.exit(0)
