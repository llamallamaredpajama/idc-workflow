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
STILL blocked on a positively stale runtime, because stale recovery code is itself unsafe. A recovery
command allowed down this path in an ALREADY-governed repo also OPENS its lifecycle record (the same
command_start path), so the Stop gate can catch abandonment and a later `finish` finds an owned record
— the emitted context claims a record, so one must actually exist. `init` is the exception: it
bootstraps a not-yet-governed repo and defers its `start` to commands/init.md (after tracker-config
exists), so it is admitted with a bootstrap context that does NOT claim a record. `janitor`
is a recovery/diagnostic sweep ("janitor remains recovery, not the primary guard") — it may run on an
invalid/unknown receipt to help the operator diagnose, and is fail-closed only on a positively stale
runtime, alongside the other recovery commands.

`IDC_HOOKS_OBSERVE_ONLY=1` is the explicit debug-only downgrade: every would-be block becomes a
stderr warning + allow.

Invocation: idc_command_entry_gate.py <PLUGIN_ROOT>   (UserPromptExpansion payload on stdin).
"""
import contextlib
import os
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # scripts/hooks/ — idc_hook_lib, idc_ledger
sys.path.insert(0, os.path.dirname(_HERE))      # scripts/ — idc_plugin_freshness, idc_command_contract
import idc_hook_lib as H  # noqa: E402
import idc_plugin_freshness as freshness  # noqa: E402
import idc_command_contract as C  # noqa: E402
import idc_ledger as L  # noqa: E402
import idc_path_gate as PG  # noqa: E402

# Fail-closed on an unverifiable freshness signal (invalid receipt / unreadable manifest / gate bug):
# the workflow commands. Running an unverifiable workflow body can re-introduce just-fixed bugs.
# `resume` belongs here because resuming puts the PIPELINE back in motion — the same reason /idc:build
# does.
WORKFLOW_COMMANDS = {"think", "intake", "plan", "build", "recirculate", "autorun", "resume"}
# May still expand on an unknown/invalid legacy receipt so the operator can diagnose or migrate the
# repo. `janitor` is a recovery/diagnostic sweep (not the primary guard), so it lives here — blocked
# only on a POSITIVELY stale runtime, never on a merely-unverifiable receipt.
# `pause` lives here for a related reason, and the asymmetry with `resume` is deliberate: pause STOPS
# work rather than starting it, writes no board state, and is the operator's graceful alternative to a
# hard kill. Refusing to let someone pause a running pipe because the install receipt has drifted would
# force exactly the ungraceful interruption this command exists to replace.
RECOVERY_COMMANDS = {"doctor", "update", "uninstall", "janitor", "pause"}
# `init` bootstraps a not-yet-governed repo: it is ALLOWED to expand but does NOT open a record in the
# entry gate — commands/init.md opens its own lifecycle record right after it writes
# tracker-config.yaml (Task 6). So init is the one governed command whose registration the entry gate
# DEFERS; every other command's record is opened here.
DEFERS_REGISTRATION = {"init"}
ALLOW_ON_INVALID = RECOVERY_COMMANDS | DEFERS_REGISTRATION

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

WRITE_FAILED_REASON = (
    "IDC refused to expand this command because it could not record the command's lifecycle "
    "obligation — the per-session state ledger (.idc-session-state.json) could not be written. "
    "Without a recorded obligation the Stop closeout gate cannot guarantee this command is closed "
    "out, so running it would leave un-enforceable state. Check that the repo root is writable, then "
    "retry the IDC command."
)

AUTH_WRITE_FAILED_REASON = (
    "IDC refused to expand this command because it could not write the shared Path Gate authorization "
    "under this repository's Git directory. Without that authorization the Write/Edit/git backstops "
    "would fail closed on every repository mutation, so the command would enter a self-contradictory "
    "state. Check that the repository Git directory is writable, then retry the IDC command."
)

AUTH_REQUIRED_COMMANDS = set(C.COMMANDS) - {"doctor", "pause"}


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


_contract_script = H.contract_script  # shared with the Stop closeout gate — one declaration


def _context(command, plugin_root):
    # The offered statuses are DERIVED from the claim table (`LEGAL_STATUSES`), never hardcoded: a
    # fixed list would offer a command statuses it cannot legally claim (and, once `paused` existed,
    # would hide the only honest way to close a deliberately-paused run).
    statuses = "|".join(sorted(C.LEGAL_STATUSES.get(command, C.TERMINAL_STATUSES)))
    return (
        f"IDC command lifecycle: `/idc:{command}` opened a governed command record. Before this "
        "session stops you MUST close it with a valid terminal status via "
        f"`{_contract_script(plugin_root)} finish --repo <repo> "
        f"--session <session-id> --command {command} --status <{statuses}>"
        " --evidence-json '<envelope>'`. The Stop closeout gate will refuse a stop "
        "that leaves this command open."
    )


def _bootstrap_context(command, plugin_root):
    """The context for an ADMITTED expansion that did NOT open a lifecycle record — `/idc:init` before
    the repo is governed, or a not-yet-governed / session-less invocation. It must NOT claim a record
    exists (Fix 2): a false "record opened" claim would tell the body an obligation is owed that the
    Stop gate cannot find. Instead it tells the command to open its OWN record once governance exists."""
    return (
        f"IDC command lifecycle: `/idc:{command}` was admitted, but NO governed command record was "
        "opened by the entry gate (this repo is not governed yet, or this command opens its own "
        f"record later). If this command establishes or repairs governance, open the record via "
        f"`{_contract_script(plugin_root)} start` after tracker-config.yaml exists, then close it "
        "with a valid terminal status before this session stops."
    )


def _emit_context(command, plugin_root, opened):
    """Emit the additionalContext that matches reality: the record-owed message iff a record was
    actually opened, otherwise the bootstrap message that claims no record."""
    if opened:
        H.prompt_expansion_context(_context(command, plugin_root))
    H.prompt_expansion_context(_bootstrap_context(command, plugin_root))


# The outcome of an attempt to open a command's lifecycle record, so the caller can emit context that
# MATCHES reality (Fix 2):
_REG_OPENED = "opened"          # the record is persisted (confirmed by a readback via the status path).
_REG_DEFERRED = "deferred"      # no record was attempted — init defers, or non-governed / session-less.
_REG_WRITE_FAILED = "write-failed"  # a governed, session-bearing repo where the ledger write did NOT persist.
_REG_CONFLICT = "conflict"      # the ledger REFUSED this start: it would narrow/replace a stamped obligation.


def _register_if_governed(payload, plugin_root, command, running=None):
    """Open (idempotent upsert) the command's active lifecycle record when this is a governed repo
    with a session to key on — the shared open-a-record path for BOTH the clean admit and the
    allow-on-invalid-receipt fork. Returns `(outcome, detail, registration)`, where outcome is one of
    `_REG_OPENED` / `_REG_DEFERRED` / `_REG_WRITE_FAILED` / `_REG_CONFLICT`, `detail` carries the
    refusal message the caller must surface (empty for the non-refusal outcomes), and `registration`
    identifies the exact persisted write this attempt made so admission can roll it back if Path Gate
    authorization fails before the command body expands.

    `init` defers its start to commands/init.md (Task 6), and a non-governed repo / missing session has
    nothing to key on, so those return `_REG_DEFERRED` and the caller emits the bootstrap context
    instead of a false "record opened" claim. When a record IS attempted, its persistence is CONFIRMED
    by a READBACK via the same read path `status` uses (`C.active_records`) — a swallowed/failed ledger
    write returns `_REG_WRITE_FAILED`, never a false "opened" (Fix 2). The running version is read
    receipt-independently, so this works even when the receipt is invalid (the caller has already
    proven the runtime is NOT positively stale); the clean-admit caller passes the version its
    freshness evaluation already read, so only the recovery fork re-reads the manifest."""
    if command in DEFERS_REGISTRATION:
        return _REG_DEFERRED, "", None
    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id")
    if not (session_id and H.is_governed_repo(cwd)):
        return _REG_DEFERRED, "", None
    if running is None:
        running = freshness.read_version(plugin_root) or ""
    try:
        with L.capture_command_start() as captured:
            written = C.register_start(cwd, session_id, command, running,
                                       payload.get("command_args") or "",
                                       payload.get("command_source") or "")
    except L.ObligationConflict as exc:
        # A narrowing/replacing restart was REFUSED by the ledger (round-6 BLOCKS 1, rule A): the PRIOR
        # obligation record is left fully intact (the ledger raises BEFORE persisting anything), and the
        # caller REFUSES the expansion with this message.
        #
        # Round-7 BLOCKS 1: this used to be SWALLOWED (`pass`), and the readback below then found the OLD
        # record and reported `_REG_OPENED` — so the gate ADMITTED the very restart the contract refuses.
        # A second `/idc:think --doc second.json --unit V0` ran with its manifest never stamped, Think
        # coverage at finish checked only the FIRST manifest, and the second manifest's units dropped
        # silently (the 2026-07-12 incident class). Surfacing the conflict as a DISTINCT outcome is what
        # makes the refusal reach the operator. It mirrors this file's OWN established principle: a
        # workflow command whose obligation cannot be RECORDED is refused (`_REG_WRITE_FAILED` below) —
        # an obligation that CONFLICTS is the same class, so it is refused the same way, with the honest
        # remediation the direct CLI already gives ("finish or reset the active run before intaking a
        # different manifest").
        return _REG_CONFLICT, str(exc), None
    # Ground-truth readback: report "opened" ONLY when the record is actually present via the status
    # read path WITH THIS ATTEMPT'S nonce. Trusting the writer's return would let a swallowed write be
    # reported as opened; accepting any same-command record would mistake a prior/concurrent record for
    # this attempt and later make a rollback capable of erasing the wrong obligation.
    captured_written = captured.get("written")
    attempt_nonce = written.get("nonce") if isinstance(written, dict) else None
    active = C.active_records(cwd, session_id)
    if (
        attempt_nonce
        and isinstance(captured_written, dict)
        and captured_written.get("session_id") == str(session_id)
        and captured_written.get("command") == command
        and captured_written.get("nonce") == attempt_nonce
        and any(
            c.get("command") == command and c.get("nonce") == attempt_nonce for c in active
        )
    ):
        return _REG_OPENED, "", {"nonce": attempt_nonce, "prior": captured.get("prior")}
    return _REG_WRITE_FAILED, "", None


def _block(reason):
    """Refuse the expansion, honoring the observe-only debug downgrade (warn + allow)."""
    if H.observe_only():
        H.warn(f"OBSERVE-ONLY (would block expansion): {reason}")
        raise SystemExit(0)
    H.prompt_expansion_block(reason)


def _path_gate_applies(payload, command):
    if command not in AUTH_REQUIRED_COMMANDS:
        return False
    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id")
    if not (session_id and H.is_governed_repo(cwd)):
        return False
    return subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--is-inside-work-tree"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    ).returncode == 0


@contextlib.contextmanager
def _admission_transaction(payload, command):
    """Hold the cross-process Path Gate lock across start -> auth/rollback -> expansion decision."""
    if not _path_gate_applies(payload, command):
        yield None
        return
    cwd = payload.get("cwd") or os.getcwd()
    try:
        with PG.admission_lock(cwd):
            yield PG.authorization_snapshot(cwd)
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001 — admission infrastructure fails closed, scrubbed
        detail = H.scrub(str(exc)).strip() or "[no exception detail]"
        H.warn(
            "idc-entry-gate: Path Gate admission transaction failed "
            f"({type(exc).__name__}): {detail}"
        )
        _block(AUTH_WRITE_FAILED_REASON)


def _restore_path_gate_auth(cwd, snapshot, expected_nonce):
    """Internal pre-expansion auth rollback; deliberately no command/CLI surface."""
    return PG.restore_authorization_snapshot(cwd, snapshot, expected_nonce)


def _fail_closed_or_allow(payload, command, why, plugin_root):
    """The unverifiable-freshness fork: fail CLOSED for the six workflow commands (block with the
    repair message); ALLOW recovery/diagnostic + init commands (they must run to diagnose or migrate
    the repo). This fork is only reached AFTER freshness has proven the runtime is NOT positively
    stale (a stale runtime is blocked upstream / by the cache-first precedence in freshness.evaluate),
    so an allowed governed recovery command safely OPENS its lifecycle record here — the emitted
    context claims a record exists, so one must actually be opened (Fix 2)."""
    if command in ALLOW_ON_INVALID:
        H.warn(f"idc-entry-gate: allowing recovery command /idc:{command} despite: {why}")
        with _admission_transaction(payload, command) as auth_snapshot:
            reg, detail, registration = _register_if_governed(payload, plugin_root, command)
            if reg == _REG_CONFLICT:
                # Defensive mirror of `_admit`: never run against an unstamped obligation.
                _block(detail)
            if reg == _REG_OPENED and not _ensure_path_gate_auth(
                payload, command, registration, auth_snapshot
            ):
                _block(AUTH_WRITE_FAILED_REASON)
            # A recovery command may still expand on a ledger write failure, but must not claim a
            # record exists. `_emit_context` is terminal and releases the lock via finally.
            _emit_context(command, plugin_root, reg == _REG_OPENED)
    _block(REPAIR_REASON)


def _ensure_path_gate_auth(payload, command, registration, auth_snapshot):
    """Write/refresh the shared Path Gate authorization for commands that legitimately mutate the
    repository. Read-only commands (`doctor`, `pause`) do not need one. The gate is keyed by the
    already-open active command record's nonce, so a later finish naturally retires it when the
    record leaves the active set.

    Registration + authorization is one admission transaction. If authorization fails, roll back
    the exact nonce this expansion wrote before the command body can run: remove a newly created
    record, or restore the prior active record that an idempotent re-entry updated. This is an
    internal-only pre-expansion repair, not a general command abort path; after expansion, lifecycle
    records may represent real work and may be closed only through the command contract."""
    if command not in AUTH_REQUIRED_COMMANDS:
        return True
    cwd = payload.get("cwd") or os.getcwd()
    session_id = payload.get("session_id")
    if not (session_id and H.is_governed_repo(cwd)):
        return True
    if not _path_gate_applies(payload, command):
        return True
    attempt_nonce = registration.get("nonce") if registration else None
    try:
        auth = PG.write_authorization(
            cwd,
            session=session_id,
            command=command,
            expected_nonce=attempt_nonce,
        )
        if auth.get("nonce") != attempt_nonce:
            raise RuntimeError("Path Gate authorization did not bind the admission attempt nonce")
        return True
    except Exception as exc:  # noqa: BLE001 — admission still blocks after a scrubbed diagnostic
        detail = H.scrub(str(exc)).strip() or "[no exception detail]"
        H.warn(
            "idc-entry-gate: Path Gate authorization write failed "
            f"({type(exc).__name__}): {detail}"
        )
        if not registration:
            H.warn(
                "idc-entry-gate: authorization rollback did not persist because this admission "
                "attempt had no exact registration nonce"
            )
            return False
        try:
            rolled_back = L.rollback_command_start(
                cwd,
                session_id,
                command,
                registration.get("nonce"),
                prior_record=registration.get("prior"),
            )
        except Exception as rollback_exc:  # noqa: BLE001 — warn, then preserve the original block
            rollback_detail = H.scrub(str(rollback_exc)).strip() or "[no exception detail]"
            H.warn(
                "idc-entry-gate: authorization rollback raised "
                f"({type(rollback_exc).__name__}): {rollback_detail}; cleanup was not confirmed"
            )
            rolled_back = False
        if not rolled_back:
            H.warn(
                "idc-entry-gate: authorization rollback did not persist; cleanup was not confirmed"
            )
            # Do not restore prior authorization while the attempt record may still be active: that
            # would manufacture a record/auth nonce mismatch. Leave current auth untouched, block the
            # admission, and surface that cleanup could not be completed.
            H.warn(
                "idc-entry-gate: authorization state rollback skipped because ledger rollback did "
                "not persist; current authorization was left unchanged"
            )
            return False
        try:
            auth_restored = _restore_path_gate_auth(cwd, auth_snapshot, attempt_nonce)
        except Exception as auth_rollback_exc:  # noqa: BLE001 — scrub, warn, preserve original block
            auth_rollback_detail = H.scrub(str(auth_rollback_exc)).strip() or "[no exception detail]"
            H.warn(
                "idc-entry-gate: authorization state rollback raised "
                f"({type(auth_rollback_exc).__name__}): {auth_rollback_detail}; "
                "cleanup was not confirmed"
            )
            auth_restored = False
        if not auth_restored:
            H.warn(
                "idc-entry-gate: authorization state rollback did not persist; "
                "cleanup was not confirmed"
            )
        return False


def _admit(payload, plugin_root, command):
    cwd = payload.get("cwd") or os.getcwd()
    # Task-1 freshness. An InvalidReceiptError (or any other exception) propagates to the caller's
    # fail-closed handler; here we only decide on a CLEAN evaluation. The cache-first precedence in
    # freshness.evaluate means a runtime behind the installed cache is reported `stale` (blocked
    # below) rather than raising, even when the receipt is invalid.
    result = freshness.evaluate(plugin_root, repo=cwd)
    if result.running_version is None:
        # The running plugin manifest could not be read → we cannot bind the runtime at all.
        _fail_closed_or_allow(payload, command,
                              "the running plugin manifest could not be read", plugin_root)
    if result.verdict == "stale":
        _block(STALE_REASON)  # blocks EVERY command, recovery ones included (stale code is unsafe)

    # Admitted on a clean, non-stale freshness signal. Open the lifecycle record (idempotent upsert)
    # when this is a governed repo with a session; init and non-governed / session-less cases emit the
    # bootstrap context instead (no false "record opened" claim).
    with _admission_transaction(payload, command) as auth_snapshot:
        reg, detail, registration = _register_if_governed(
            payload, plugin_root, command, running=result.running_version or ""
        )
        if reg == _REG_CONFLICT:
            # The ledger refused to narrow/replace the active obligation. Surface its remediation;
            # admitting instead would run a command whose obligation Stop could not enforce.
            _block(detail)
        if reg == _REG_WRITE_FAILED and command in WORKFLOW_COMMANDS:
            # A workflow command must not run unrecorded; Stop could not enforce its closeout.
            _block(WRITE_FAILED_REASON)
        if reg == _REG_OPENED and not _ensure_path_gate_auth(
            payload, command, registration, auth_snapshot
        ):
            _block(AUTH_WRITE_FAILED_REASON)
        _emit_context(command, plugin_root, reg == _REG_OPENED)


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
        _fail_closed_or_allow(payload, command, f"unexpected gate error: {exc}", plugin_root)
    sys.exit(0)


if __name__ == "__main__":
    main()
