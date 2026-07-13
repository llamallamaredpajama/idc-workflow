#!/usr/bin/env python3
"""idc_command_contract.py — the universal IDC command lifecycle contract (Task 2, command integrity).

A governed `/idc:*` command is an OBLIGATION: it is ENTERED (a lifecycle record opens in the session
ledger) and it must be CLOSED with a valid terminal status. This module is the runtime-neutral façade
over that contract — the same validation and the same single ledger write door whether the caller is a
Claude hook, a command's markdown tail, Codex, or Pi. It owns three responsibilities:

  * `start`  — open (idempotently upsert) the command's active record, AFTER a Task-1 freshness check:
               a stale plugin runtime must never open a record (exit 4, no write), because a stale
               command body would record an obligation it cannot honestly discharge.
  * `finish` — close an existing active record owned by this session with a validated terminal status
               + evidence envelope. Rejects an unknown command/status, malformed JSON, an invalid
               envelope, a missing active record, or a foreign session.
  * `status` — read the session's active + finished command records (for the Stop closeout gate's
               human remediation and for tests).

There is DELIBERATELY no `abort-stale` / erase op: an agent cannot make an obligation disappear
without a valid terminal status. The only way out of an open command is an honest `finish`.

ENVELOPE SCOPE (this task). `finish` validates only the COMMON evidence envelope — `schema_version`
== 1 and `refs` is an object. Command-SPECIFIC evidence checks (a think closeout must carry a
think_pr, a build closeout its merged PR, …) land in Task 6, BEFORE any shipped command is allowed to
use the terminal states. Keeping the two phases separate means this task ships the envelope and the
write door without prejudging each command's evidence shape.

CLI:
  idc_command_contract.py start  --repo R --session S --command C --plugin-root P [--args T] [--source T]
  idc_command_contract.py finish --repo R --session S --command C --status STATUS --evidence-json JSON
  idc_command_contract.py status --repo R [--session S] [--json]
Exit codes: 0 = ok; 4 = stale runtime (start only, no record written); 2 = invalid input (unknown
command/status, malformed JSON, invalid evidence envelope, an invalid receipt, or a missing/foreign
active record on finish).
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # scripts/ — for idc_plugin_freshness
sys.path.insert(0, os.path.join(_HERE, "hooks"))  # scripts/hooks/ — for idc_ledger
import idc_plugin_freshness as freshness  # noqa: E402
import idc_ledger  # noqa: E402

# The eleven governed `/idc:*` entry points. Kept in lockstep with commands/*.md and the
# UserPromptExpansion matcher in hooks/hooks.json.
COMMANDS = {
    "autorun", "build", "doctor", "init", "intake", "janitor",
    "plan", "recirculate", "think", "uninstall", "update",
}
# The four honest ways a command lifecycle can END. Task 6 attaches command-specific evidence to each.
TERMINAL_STATUSES = {"complete", "waiting_gate", "no_action", "blocked_external"}


@dataclasses.dataclass(frozen=True)
class CloseoutResult:
    ok: bool
    reason_code: str
    message: str
    normalized_evidence: dict


def args_digest(text: str) -> str:
    """The lowercase-hex SHA-256 of the command's raw argument text — a stable, non-reversible
    fingerprint recorded on the lifecycle record (so a closeout can be tied to the exact invocation
    without persisting the possibly-sensitive argument text itself)."""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def validate_closeout(command: str, status: str, evidence: object) -> CloseoutResult:
    """Validate a closeout's command, terminal status, and COMMON evidence envelope (this task).
    Returns a CloseoutResult; ok=False carries a machine reason_code + a human message. The envelope
    contract: evidence is a JSON object with `schema_version == 1` and `refs` an object. Command-
    specific evidence checks are Task 6."""
    if command not in COMMANDS:
        return CloseoutResult(False, "unknown-command", f"unknown command {command!r}", {})
    if status not in TERMINAL_STATUSES:
        return CloseoutResult(
            False, "unknown-status",
            f"unknown terminal status {status!r} (expected one of {sorted(TERMINAL_STATUSES)})", {})
    if not isinstance(evidence, dict):
        return CloseoutResult(False, "evidence-not-object", "evidence must be a JSON object", {})
    schema_version = evidence.get("schema_version")
    # STRICT: the INTEGER 1 only. Python's `True == 1` and `1.0 == 1`, so a bare `!= 1` would admit
    # JSON `true` (bool) and `1.0` (float). Reject bool explicitly (bool is a subclass of int) and
    # any non-int type, so only a genuine integer 1 passes.
    if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != 1:
        return CloseoutResult(
            False, "bad-schema-version",
            f"evidence.schema_version must be the integer 1, got {schema_version!r}", {})
    if not isinstance(evidence.get("refs"), dict):
        return CloseoutResult(False, "refs-not-object", "evidence.refs must be an object", {})
    return CloseoutResult(True, "ok", "closeout envelope valid", evidence)


def register_start(cwd: str, session_id: str, command: str, plugin_version: str,
                   args_text: str, source: str) -> dict:
    """Open (idempotently upsert) the command's active lifecycle record — the entry gate's helper.
    Computes the argument digest and delegates the single ledger write. Assumes freshness/admission
    was already decided by the caller (the entry gate). Returns the record dict when the write
    PERSISTED, `{}` outside a governed repo, or None when the ledger write FAILED (Fix 2)."""
    return idc_ledger.command_start(
        cwd, session_id, command, plugin_version, args_digest(args_text or ""), source or "")


def active_records(cwd: str, session_id: str) -> list:
    """The active command records for `session_id` — the SAME read path `status` reports from
    (idc_ledger.active_commands). Exposed so the entry gate can READ BACK after a start and CONFIRM
    the record actually persisted, rather than trusting the writer's return (Fix 2)."""
    return idc_ledger.active_commands(cwd, session_id)


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
def _cmd_start(args) -> int:
    if args.command not in COMMANDS:
        print(f"idc-command-contract: unknown command {args.command!r}", file=sys.stderr)
        return 2
    try:
        result = freshness.evaluate(args.plugin_root, repo=args.repo)
    except freshness.InvalidReceiptError as exc:
        print(f"idc-command-contract: invalid receipt: {exc}", file=sys.stderr)
        return 2
    # A stale runtime must never OPEN an obligation: a stale command body would record work it cannot
    # honestly discharge. Exit 4 without writing a record (the admission gate has already refused the
    # expansion; this is the second, write-side guard for any non-hook caller).
    if result.verdict == "stale":
        print("idc-command-contract: refusing to open a command record on a stale plugin runtime "
              f"(running {result.running_version}, required {result.required_version}); "
              "run /reload-plugins, then retry.", file=sys.stderr)
        return 4
    rec = register_start(args.repo, args.session, args.command, result.running_version or "",
                         args.args or "", args.source or "")
    if rec is None:
        # A governed repo where the ledger write did NOT persist. Never report success for an
        # obligation that was not recorded (Fix 2) — the Stop gate could not enforce its closeout.
        print("idc-command-contract: could not persist the command record (the session state "
              "ledger write failed — check that the repo root is writable), so no obligation was "
              "opened.", file=sys.stderr)
        return 1
    return 0


def _cmd_finish(args) -> int:
    try:
        evidence = json.loads(args.evidence_json)
    except ValueError as exc:
        print(f"idc-command-contract: malformed --evidence-json: {exc}", file=sys.stderr)
        return 2
    verdict = validate_closeout(args.command, args.status, evidence)
    if not verdict.ok:
        print(f"idc-command-contract: rejected closeout [{verdict.reason_code}]: {verdict.message}",
              file=sys.stderr)
        return 2
    rec = idc_ledger.command_finish(
        args.repo, args.session, args.command, args.status, verdict.normalized_evidence)
    if rec is None:
        print(f"idc-command-contract: no active {args.command!r} command record owned by session "
              f"{args.session!r} to finish (a foreign session cannot finish another's record)",
              file=sys.stderr)
        return 2
    return 0


def _cmd_status(args) -> int:
    active = idc_ledger.active_commands(args.repo, args.session)
    finished = [c for c in idc_ledger.read_state(args.repo)["commands"]
                if c.get("state") != "active"]
    if args.session:
        finished = [c for c in finished if c.get("session_id") == args.session]
    if args.json:
        print(json.dumps({"active": active, "finished": finished}, indent=2, sort_keys=True))
    else:
        for c in active:
            print(f"active  {c.get('session_id')}  {c.get('command')}")
        for c in finished:
            closeout = c.get("closeout") or {}
            print(f"done    {c.get('session_id')}  {c.get('command')}  {closeout.get('status')}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="IDC command lifecycle contract (runtime-neutral)")
    sub = ap.add_subparsers(dest="op", required=True)

    sp = sub.add_parser("start", help="open (upsert) a command's active lifecycle record")
    sp.add_argument("--repo", required=True)
    sp.add_argument("--session", required=True)
    sp.add_argument("--command", required=True)
    sp.add_argument("--plugin-root", required=True)
    sp.add_argument("--args", default="")
    sp.add_argument("--source", default="")

    fp = sub.add_parser("finish", help="close an active command with a validated terminal status")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--session", required=True)
    fp.add_argument("--command", required=True)
    fp.add_argument("--status", required=True)
    fp.add_argument("--evidence-json", required=True)

    tp = sub.add_parser("status", help="show the session's active + finished command records")
    tp.add_argument("--repo", required=True)
    tp.add_argument("--session", default=None)
    tp.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    if args.op == "start":
        return _cmd_start(args)
    if args.op == "finish":
        return _cmd_finish(args)
    if args.op == "status":
        return _cmd_status(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
