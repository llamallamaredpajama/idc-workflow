#!/usr/bin/env python3
"""idc_pause_state.py — the durable pause record, and the ONE door that writes it.

WHAT THIS IS. A tiny, dependency-free sidecar to the obligations ledger, in the same family as
`idc_drain_verdict.py`: one JSON file, `.idc-pause-state.json`, at the governed workspace root, saying
whether this repo's pipeline run is deliberately PAUSED. It exists because a long autonomous run needs
a way to be stopped on purpose and picked up later, and none of the state IDC already keeps can say
that: the board records the WORK, the ledger records a session's OBLIGATIONS, and neither can express
"a human stopped this run and intends to come back to it".

THE RECORD IS NOT THE STATE OF THE WORK. The board remains the durable state of the work, exactly as
`/idc:autorun` already assumes — every pass re-reads it and continues from it. This file adds ONE
fact the board cannot hold: the run is paused. That is deliberately all it holds, because anything
else would be a second source of truth about work, and resume would then have to reconcile two.

  {
    "version": 1,
    "state": "pause-requested" | "paused",
    "session_id": "S1",              # the session that asked for the pause
    "command": "autorun",            # what was being run when the pause was asked for (optional)
    "note": "operator's words",      # optional
    "requested_ts": 1720137600.0,
    "confirmed_ts": 1720137605.0,    # present ONLY on `paused`
    "quiescence": {"verdict": "ok", "checked_ts": ...}   # present ONLY on `paused`
  }

THE TWO STATES, AND WHY BOTH ARE NEEDED.
  * `pause-requested` — a pause was ASKED FOR but is NOT yet honest: something was still in flight, or
    quiescence could not be established. This state deliberately does NOT count as paused anywhere: the
    Stop fixpoint gate ignores it, and `/idc:resume` treats clearing it as a plain no-op. It exists so
    that a session which dies between "pause requested" and "pause confirmed" leaves a TRUE record of
    what happened rather than a false claim of a clean stop.
  * `paused` — the pause is real. `confirm()` writes it and CANNOT be talked into it: it RUNS
    `idc_pause_check.py` itself and refuses on any nonzero exit. There is no caller-supplied
    "everything is fine" parameter, because the whole value of a pause is the promise that nothing is
    half-done, and a promise the caller makes about itself is not evidence.

WHO READS IT.
  * `scripts/hooks/idc_stop_fixpoint_gate.py` — a confirmed pause is an honest, recorded, resumable
    stop, so the gate allows it instead of refusing the stop over a non-empty inbox.
  * `scripts/idc_command_contract.py` — the `paused` terminal status for a pipeline command requires
    this record AND a fresh re-run of the quiescence check, so a recorded pause can never outlive the
    proof that justified it.
  * `/idc:resume` and `/idc:autorun`'s preflight — both clear it and continue from the board.

FAIL MODES (mirror the ledger + the drain verdict). Reads are TOLERANT: a missing or corrupt file
reads as "not paused" and never throws — a corrupt record must not brick a gate, and the honest
reading of an unreadable pause record is that no pause is proven. Writes are ATOMIC (temp-file +
os.replace) and REPO-GATED (a no-op outside an IDC-governed repo), but — unlike a taint — they are NOT
best-effort-silent: `request`/`confirm` SURFACE a failed write as a nonzero exit, because a pause the
operator believes was recorded and was not is precisely the corruption this command exists to prevent.

IDEMPOTENCE (the awkward cases, all of which must be safe). Pausing twice is a no-op that reports the
existing pause and never regresses `paused` back to `pause-requested`. Pausing when nothing is running
is legitimate and still records a pause — "do not start anything new" is a meaningful instruction even
with an empty board. Resuming when nothing is paused reports `resume: not-paused` and exits 0.

CLI:
  idc_pause_state.py --cwd R path
  idc_pause_state.py --cwd R status [--json]
  idc_pause_state.py --cwd R request --session S [--command C] [--note N]
  idc_pause_state.py --cwd R confirm --session S [--backend B] [--tracker P] [--owner O] [--project N]
  idc_pause_state.py --cwd R resume  --session S
  idc_pause_state.py --cwd R close-open --session S      # close this session's open pipeline records
  idc_pause_state.py --cwd R ensure-gitignore
Exit codes: 0 ok · 1 the write did not persist / no record to act on · 2 invalid input, an ungoverned
repo, or (on `confirm`) the quiescence check REFUSED the pause — its own exit is echoed in `check_exit`.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "hooks"))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, defined once, shared)
import idc_ledger  # noqa: E402
import idc_pause_check  # noqa: E402

PAUSE_FILENAME = ".idc-pause-state.json"
# One glob line ignores the record and any future sidecar (`*` matches the empty string), mirroring
# `.idc-session-state.json*` and `.idc-drain-verdict.json*`.
GITIGNORE_LINE = PAUSE_FILENAME + "*"
_VERSION = 1
REQUESTED = "pause-requested"
PAUSED = "paused"
_ACTIVE_STATES = (REQUESTED, PAUSED)


def pause_path(cwd) -> str:
    """The `.idc-pause-state.json` path at the governed workspace root `cwd`."""
    return os.path.join(cwd or ".", PAUSE_FILENAME)


# ── tolerant read ────────────────────────────────────────────────────────────────────────────────
def read_record(cwd):
    """The pause record dict, or None. TOLERANT: a missing, unreadable, corrupt, or shape-invalid file
    reads as None — never throws. An unreadable record is NOT a proven pause, which is the fail-closed
    reading for every consumer (the stop gate then re-runs the drain; the closeout then refuses)."""
    try:
        with open(pause_path(cwd), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("state") not in _ACTIVE_STATES:
        return None
    return data


# ── the confirmation witness: proof that a REAL confirm ran in THIS working copy ──────────────────
# WHY THE RECORD ALONE CANNOT CARRY THIS. `.idc-pause-state.json` sits at the workspace root and every
# field in it is a value a caller can type: `version`/`state`/`quiescence.verdict` are constants, the
# two ids are arbitrary strings, the two timestamps arbitrary numbers. The Stop fixpoint gate treats a
# confirmed record as a BYPASS — it allows a stop WITHOUT proving the pipe is drained — so validating
# that record's shape, however many fields, only raises the cost of forgery from one `Write` to one
# slightly longer `Write`. It is the same argument `idc_live_check.py` makes about a portable receipt
# ("every value in a portable record must be one any reader can recompute — and anything a reader can
# recompute, a forger can write"), and it takes the same answer: leave a corroborating mark where the
# honest path leaves one and a typed file does not.
#
# THIS CHECKOUT'S GIT DIRECTORY, deliberately NOT the shared one `idc_live_check` uses. What each
# witness vouches for has a different scope: a live receipt is a COMMITTED artifact that travels
# between checkouts, so its witness belongs to the repository (and must survive worktree teardown);
# the pause record is a per-workspace sidecar that never travels, so its witness belongs to the same
# workspace and should die with it. A linked worktree's pause is its own.
#
# WHAT THIS PROVES, stated plainly rather than overclaimed: that a real `confirm` ran in this working
# copy and produced EXACTLY this record. It does NOT prove that nobody edited the git directory.
# Nothing local can prove that, and a signature would not help — the key would have to live here too.
_WITNESS_REL = os.path.join("idc", "pause-confirmations.json")
_WITNESS_VERSION = 1


def _git_dir(cwd):
    """This checkout's git directory (absolute), or None when git cannot answer."""
    try:
        r = subprocess.run(["git", "-C", cwd or ".", "rev-parse", "--absolute-git-dir"],
                           capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    out = (r.stdout or "").strip()
    return out if r.returncode == 0 and out else None


def record_digest(rec) -> str:
    """A digest over the record's CANONICAL form, so the witness names one exact record.

    Canonical (sorted keys, no whitespace) rather than the file's bytes, because the on-disk
    formatting is the writer's business and a reader must reach the same answer from the parsed dict.
    """
    return hashlib.sha256(
        json.dumps(rec, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def witness_path(cwd):
    """`<git-dir>/idc/pause-confirmations.json`, or None when there is no git directory."""
    d = _git_dir(cwd)
    return os.path.join(d, _WITNESS_REL) if d else None


def read_witness(cwd):
    """The digest this checkout recorded for its confirmed pause, or None. TOLERANT: anything
    unreadable reads as "no confirmation is proven", which withholds the bypass rather than granting
    it — damaging this file can only ever cost a re-pause."""
    path = witness_path(cwd)
    if path is None:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("version") != _WITNESS_VERSION:
        return None
    digest = data.get("digest")
    return digest if isinstance(digest, str) and digest.strip() else None


def _record_confirmation(cwd, rec) -> bool:
    """Record that THIS working copy really confirmed exactly `rec`. Returns whether it persisted."""
    path = witness_path(cwd)
    if path is None:
        return False
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
    except OSError:
        return False
    return idc_hook_lib.atomic_write_json(
        path, {"version": _WITNESS_VERSION, "digest": record_digest(rec),
               "session_id": str(rec.get("confirmed_by") or ""),
               "confirmed_ts": rec.get("confirmed_ts")},
        prefix=".idc-pause-witness.", label="pause-witness")


def _clear_confirmation(cwd) -> None:
    """Drop the witness when the pause is lifted. Best-effort: a witness with no record grants
    nothing (every reader looks at the record first), so a failure here cannot manufacture a pause."""
    path = witness_path(cwd)
    if path is None:
        return
    try:
        os.remove(path)
    except OSError:
        pass


def is_paused(cwd) -> bool:
    """True ONLY for a CONFIRMED pause. A `pause-requested` record is not a pause: it means the pause
    was asked for and never proven honest, so nothing may treat it as a clean stop."""
    rec = read_record(cwd)
    return bool(rec) and rec.get("state") == PAUSED


# ── atomic write ─────────────────────────────────────────────────────────────────────────────────
def _atomic_write(cwd, payload) -> bool:
    """Write the record atomically (temp-file + os.replace, so a concurrent reader never sees a
    half-written file). Returns True iff it actually PERSISTED — the caller SURFACES a False rather
    than reporting a pause that was never recorded."""
    return idc_hook_lib.atomic_write_json(pause_path(cwd), payload, prefix=".idc-pause.",
                                          label="pause-state")


def request(cwd, session_id, command=None, note=None, ts=None):
    """Record that a pause was ASKED FOR. Returns `(record, created)`.

    Idempotent and NEVER regressive: an existing `paused` record is returned untouched (`created` is
    False), so pausing twice is a safe no-op and a confirmed pause is never downgraded to a request by
    a second `/idc:pause`. Returns `(None, False)` when the write did not persist."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return None, False
    if not str(session_id or "").strip():
        return None, False
    existing = read_record(cwd)
    if existing is not None:
        return existing, False
    rec = {"version": _VERSION, "state": REQUESTED, "session_id": str(session_id),
           "requested_ts": float(ts if ts is not None else time.time())}
    if command:
        rec["command"] = str(command)
    if note:
        rec["note"] = str(note)
    return (rec, True) if _atomic_write(cwd, rec) else (None, False)


def confirm(cwd, session_id, backend=None, tracker=None, owner=None, project=None, timeout=180,
            ts=None):
    """Promote the record to `paused` — but ONLY after RE-DERIVING quiescence for real.

    Returns `(record, code, verdict, findings)`. `code` is `idc_pause_check`'s own exit: 0 means the
    pause was recorded; 1 means something is still half-done; 2 means quiescence could not be
    established. On any nonzero the record is left in / moved to `pause-requested` — an honest "asked
    for, not achieved" — and NO pause is claimed. There is deliberately no override parameter."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return None, 2, "error", [{"kind": "error", "ref": "not a governed IDC repo", "cure":
                                   "run /idc:init first — a pause is a statement about a governed pipeline"}]
    # THE SAME GUARD `request` HAS, and it belongs here rather than in the CLI arm. The strictest
    # reader of this record — the Stop gate's `_is_paused` — refuses a blank `session_id`/`confirmed_by`,
    # so a writer that accepts one produces a record the operator is told succeeded and the gate then
    # treats as dishonest, blocking the stop three times before loud-fail-allowing it. The writer must
    # enforce what its strictest reader requires.
    if not str(session_id or "").strip():
        return None, 2, "error", [{"kind": "error", "ref": "a pause must name the session confirming it",
                                   "cure": "pass --session \"$CLAUDE_CODE_SESSION_ID\"; a pause with no "
                                           "session identity cannot be attributed to any run"}]
    code, verdict, findings = idc_pause_check.check(cwd, backend=backend, tracker=tracker, owner=owner,
                                                    project=project, timeout=timeout)
    existing = read_record(cwd)
    if code != 0:
        # Not honest yet. Keep (or open) the REQUEST so the true state is durable, but never claim a
        # pause. An already-confirmed pause is left alone: quiescence going stale later is the next
        # pause's problem, not a reason to silently un-pause a run the operator already stopped.
        if existing is None:
            request(cwd, session_id, ts=ts)
        return read_record(cwd), code, verdict, findings
    now = float(ts if ts is not None else time.time())
    rec = dict(existing or {"version": _VERSION, "session_id": str(session_id), "requested_ts": now})
    rec.update({"version": _VERSION, "state": PAUSED, "confirmed_ts": now,
                "confirmed_by": str(session_id),
                "quiescence": {"verdict": verdict, "checked_ts": now}})
    # THE WITNESS IS WRITTEN FIRST, and the order is the safe one. A witness with no `paused` record
    # grants nothing — every reader looks at the record first — whereas a `paused` record with no
    # witness is a pause the operator believes they took and the Stop gate will not honour. So a crash
    # between the two leaves the WEAKER state (still `pause-requested`), which re-running clears.
    if not _record_confirmation(cwd, rec):
        return None, 1, "witness-failed", [
            {"kind": "error",
             "ref": "the confirmation could not be recorded in the git directory",
             "cure": "the pause was NOT recorded. Check that this is a git repository and that its "
                     "git directory is writable, then re-run /idc:pause — without this mark nothing "
                     "can tell your pause apart from a hand-written one, and the Stop gate would "
                     "refuse the stop it is supposed to allow"}]
    if not _atomic_write(cwd, rec):
        _clear_confirmation(cwd)   # no record to vouch for; leave nothing behind
        return None, 1, "write-failed", [{"kind": "error", "ref": "the pause record did not persist",
                                          "cure": "check that the repo root is writable, then re-run "
                                                  "/idc:pause"}]
    return rec, 0, verdict, []


class ClearFailed(RuntimeError):
    """The pause record is still on disk after a resume tried to remove it."""


def clear(cwd):
    """Remove the pause record. Returns the record that WAS there (so the caller can report what it
    resumed), or None when nothing was paused — an honest no-op, never an error. Removing an already
    absent record is a no-op too.

    DELIBERATELY NOT SESSION-SCOPED, which is why this takes no session id. The session that paused a
    run is, by the time anyone resumes it, usually gone — that is the whole point of a durable pause
    record — so a dead session's pause MUST be clearable by whoever comes next. This once accepted a
    `session_id` it never used, which implied the opposite of the design.

    A removal that FAILS raises `ClearFailed`, and that distinction is load-bearing. Returning None
    there — which is what the first cut did — is indistinguishable from "nothing was paused", so
    `/idc:resume` printed `not-paused` and exited 0 while the confirmed pause record was still sitting
    in the repo. The run then starts working again, and the Stop gate, reading that surviving record,
    trusts it and allows an undrained walk-away: a pause that was never lifted is used to excuse a stop
    that was never clean. "I could not un-pause this" and "this was not paused" must never collapse
    into one answer."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return None
    rec = read_record(cwd)
    path = pause_path(cwd)
    try:
        os.remove(path)
    except FileNotFoundError:
        _clear_confirmation(cwd)
        return rec
    except OSError as e:
        raise ClearFailed(f"could not remove the pause record {path}: {e}") from e
    # Only after the record is gone: the witness alone proves nothing, but leaving it behind would let
    # a later hand-written copy of the SAME record be honoured again.
    _clear_confirmation(cwd)
    return rec


# ── closing the open pipeline records a pause interrupts ─────────────────────────────────────────
# The commands whose lifecycle record may honestly close as `paused`. Kept in lockstep with the
# claim table in idc_command_contract.py, which is the enforcing side — this list only decides WHICH
# open records this helper offers to close, and every close still goes through the validating door.
def _pausable_commands():
    import idc_command_contract as CONTRACT  # noqa: E402 — lazy; the claim table is the authority
    return {cmd for cmd, statuses in CONTRACT.LEGAL_STATUSES.items() if CONTRACT.PAUSED in statuses}


# The command that DRIVES this walk. `/idc:pause` is the one running `close-open`, so its own
# lifecycle record is not interrupted work — it is the driver, and it closes itself through its own
# closeout gate (`complete`, or `blocked_external` on a refused pause) once the walk is done.
_DRIVER_COMMAND = "pause"


def close_open_commands(cwd, session_id, driver=_DRIVER_COMMAND):
    """Close every still-open PIPELINE command record owned by `session_id` with the `paused` terminal
    status, through the validating command-contract door (never a raw ledger write).

    This is what makes a pause honest at the lifecycle layer: the run the operator stopped was holding
    an open obligation (`/idc:autorun`, `/idc:build`, …) and the Stop closeout gate refuses a walk-away
    from one. Before `paused` existed there was no truthful way to close it — `complete` would have
    claimed a drained pipe. Returns `(closed, refused)` lists of `(command, message)`.

    THE DRIVER'S OWN RECORD IS SKIPPED, and that is not a special case bolted on. The command entry
    gate opens a lifecycle record for every command but `init`, so a REAL `/idc:pause` always has an
    open `pause` record when `commands/pause.md` step 4 runs this walk. `pause` is not a pausable
    stage, so the walk used to refuse the very command doing the pausing: every honest pause printed
    `/idc:pause REFUSED [paused-stage-unobservable] …` — telling the operator to "finish or abandon"
    the pause they were in the middle of taking — and exited 1, which `commands/pause.md` reads as a
    failed pause. A refusal that fires on the success path is noise, and noise on a success path is
    how an operator learns to ignore a real refusal.

    The skip is narrow on purpose: only the driving command, only in this session's own records. Every
    other unpausable stage (`think`/`intake`/`plan`) is still REFUSED BY NAME, which is the honest
    report of what the pause did not cover (`phase4-completion-honesty.sh` H7 holds that).
    """
    import idc_command_contract as CONTRACT  # noqa: E402 — lazy
    pausable = _pausable_commands()
    closed, refused = [], []
    for rec in idc_ledger.active_commands(cwd, session_id):
        command = rec.get("command")
        if command == driver:
            continue
        if command not in pausable:
            # SAY SO, rather than skipping quietly. `paused` is only claimable by the stages whose
            # half-done work the quiescence checker can observe (build/autorun/recirculate — see
            # `_PAUSABLE_STAGES` in idc_command_contract.py). A mid-think/intake/plan run leaves its
            # partial work in a branch and a document, which nothing here reads, so certifying it as a
            # clean stop would be a promise with no checker behind it. Reporting it as REFUSED keeps
            # the record open and honest: the operator sees exactly what the pause did not cover.
            refused.append((command, f"[paused-stage-unobservable] /idc:{command} has no honest "
                                     f"`paused` closeout: what it leaves half-done (a partly written "
                                     f"document, manifest, or decomposition on a branch) is not "
                                     f"something the quiescence check can observe, so a clean-stop "
                                     f"claim here would be unbacked. Finish or abandon this run "
                                     f"deliberately; the pause covers the build/autorun/recirculate "
                                     f"work only"))
            continue
        evidence = {"schema_version": 1, "refs": {}}
        verdict = CONTRACT.validate_closeout(command, CONTRACT.PAUSED, evidence,
                                             repo=cwd, session=session_id)
        if not verdict.ok:
            refused.append((command, f"[{verdict.reason_code}] {verdict.message}"))
            continue
        if idc_ledger.command_finish(cwd, session_id, command, CONTRACT.PAUSED,
                                     verdict.normalized_evidence) is None:
            refused.append((command, "the closeout write did not persist"))
            continue
        closed.append((command, "closed as paused"))
    return closed, refused


# ── the gitignore scaffold hook (idempotent, non-destructive) ─────────────────────────────────────
def ensure_gitignored(repo_root) -> bool:
    """Ensure the repo-root `.gitignore` ignores the pause record, idempotently and NON-destructively.
    REPO-GATED. Now genuinely DELEGATES to the shared sidecar implementation — the docstring here used
    to claim that while carrying its own copy, which had already drifted from its three siblings (it
    appended a provenance comment even when the existing file ended in a comment or a colon)."""
    return idc_hook_lib.ensure_gitignored(
        repo_root, GITIGNORE_LINE, label="pause-state",
        created_comment="# IDC pause record (deliberate run pause; local state, do not commit)",
        appended_comment="# IDC pause record (deliberate run pause; local state, do not commit)")


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
def _describe(rec) -> str:
    if rec is None:
        return "pause: none"
    who = rec.get("session_id") or "?"
    what = rec.get("command")
    tail = f" (command {what})" if what else ""
    if rec.get("state") == PAUSED:
        return f"pause: paused by {who}{tail}"
    return f"pause: requested by {who}{tail} — NOT yet confirmed as a clean stop"


def _cmd_status(args) -> int:
    rec = read_record(args.cwd)
    if args.json:
        print(json.dumps({"paused": is_paused(args.cwd), "record": rec}, indent=2, sort_keys=True))
    else:
        print(_describe(rec))
    return 0


def _cmd_request(args) -> int:
    if not idc_hook_lib.is_governed_repo(args.cwd):
        print("idc-pause-state: not an IDC-governed repo — nothing to pause", file=sys.stderr)
        return 2
    if not (args.session or "").strip():
        print("idc-pause-state: refusing to record a pause without a session identity", file=sys.stderr)
        return 2
    rec, created = request(args.cwd, args.session, command=args.command, note=args.note)
    if rec is None:
        print("idc-pause-state: the pause record did not persist (is the repo root writable?)",
              file=sys.stderr)
        return 1
    print("pause: requested" if created else f"pause: already-recorded — {_describe(rec)}")
    return 0


def _cmd_confirm(args) -> int:
    rec, code, verdict, findings = confirm(args.cwd, args.session, backend=args.backend,
                                           tracker=args.tracker, owner=args.owner,
                                           project=args.project, timeout=args.timeout)
    if code == 0 and rec is not None:
        print("pause: paused")
        print("pause-ready: ok")
        return 0
    # Loud, specific, and never a clean-looking exit: name every half-done thing and its cure.
    print(f"pause: NOT paused (check_exit {code})")
    idc_pause_check.report(code, verdict, findings)
    sys.stdout.flush()   # so the loud stderr line lands AFTER the findings it refers to
    print("pause: the run was NOT recorded as cleanly paused — resolve the items above and re-run "
          "/idc:pause, or stop knowing the work is unfinished.", file=sys.stderr)
    return 2 if code != 1 else 1


def _cmd_resume(args) -> int:
    if not idc_hook_lib.is_governed_repo(args.cwd):
        print("idc-pause-state: not an IDC-governed repo — nothing to resume", file=sys.stderr)
        return 2
    try:
        # No session id: resume is deliberately unscoped — see `clear`.
        rec = clear(args.cwd)
    except ClearFailed as e:
        # Fail CLOSED and loudly: the record survived, so this repo is still paused. Exiting 0 here
        # would hand the caller a resume it did not get, and leave a stale pause record behind for the
        # Stop gate to excuse an undrained stop with.
        print(f"resume: error {e}", file=sys.stderr)
        print("resume: error the pause record could not be removed — this repo is STILL PAUSED. "
              f"cure: make {pause_path(args.cwd)} writable (check permissions and ownership), then "
              f"re-run /idc:resume")
        return 2
    if rec is None:
        print("resume: not-paused")          # honest no-op, exit 0
        return 0
    print(f"resume: cleared ({rec.get('state')})")
    return 0


def _cmd_close_open(args) -> int:
    if not (args.session or "").strip():
        print("idc-pause-state: --session is required to close this session's records", file=sys.stderr)
        return 2
    closed, refused = close_open_commands(args.cwd, args.session)
    for command, msg in closed:
        print(f"paused-record: /idc:{command} {msg}")
    for command, msg in refused:
        print(f"paused-record: /idc:{command} REFUSED {msg}", file=sys.stderr)
    if not closed and not refused:
        print("paused-record: none open")
    return 1 if refused else 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="IDC durable pause record (the single write door)")
    ap.add_argument("--cwd", default=".", help="governed workspace root (default: cwd)")
    sub = ap.add_subparsers(dest="op", required=True)

    sub.add_parser("path", help="print the pause record path")
    sub.add_parser("ensure-gitignore", help="idempotently ignore the pause record")

    sp = sub.add_parser("status", help="report whether this repo's run is paused")
    sp.add_argument("--json", action="store_true")

    rp = sub.add_parser("request", help="record that a pause was asked for")
    rp.add_argument("--session", required=True)
    rp.add_argument("--command", default=None, help="the command being run when the pause was asked for")
    rp.add_argument("--note", default=None)

    cp = sub.add_parser("confirm", help="promote the request to a confirmed pause (re-derives quiescence)")
    cp.add_argument("--session", required=True)
    cp.add_argument("--backend", choices=("filesystem", "github"), default=None)
    cp.add_argument("--tracker", default=None)
    cp.add_argument("--owner", default=None)
    cp.add_argument("--project", default=None)
    cp.add_argument("--timeout", type=int, default=180)

    up = sub.add_parser("resume", help="clear the pause record (honest no-op when nothing is paused)")
    # Accepted (the shipped /idc:resume and /idc:autorun preflight both pass it) and used ONLY for the
    # caller's own attribution — resume NEVER filters the pause record by session. A pause outlives the
    # session that set it, so scoping the removal would strand exactly the records resume exists to lift.
    up.add_argument("--session", default=None)

    op = sub.add_parser("close-open", help="close this session's open pipeline records as `paused`")
    op.add_argument("--session", required=True)

    args = ap.parse_args(argv)
    args.cwd = os.path.abspath(args.cwd)
    if args.op == "path":
        print(pause_path(args.cwd))
        return 0
    if args.op == "ensure-gitignore":
        ensure_gitignored(args.cwd)
        return 0
    return {"status": _cmd_status, "request": _cmd_request, "confirm": _cmd_confirm,
            "resume": _cmd_resume, "close-open": _cmd_close_open}[args.op](args)


if __name__ == "__main__":
    raise SystemExit(main())
