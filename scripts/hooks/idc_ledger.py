#!/usr/bin/env python3
"""idc_ledger.py — the per-session obligations ledger (v4 Phase 3, plan §3.4).

WHAT THIS IS. A tiny, dependency-free state store that DETERMINISTIC hooks/scripts — **never the
LLM** — use to record and clear *obligation taints* accrued during a session, so later gates
(Phase 3's Stop / SubagentStop) can ask "does this session still owe work?" WITHOUT a board scan.
It is the file-backed-labels half of Omnigent's stateful-policy pattern; the gates are the policy.

THE FILE. One JSON file, `.idc-session-state.json`, at the **governed workspace root**
(`ledger_path(cwd)`). It is transient working state, gitignored via the scaffold
(`ensure_gitignored()`, wired into idc_init_scaffold.sh + /idc:update) so a clean autorun/build exit
never leaves committed litter. PRIMARY FORMAT — v2 (Task 2, command integrity), carrying BOTH the v1
`taints` array AND a `commands` array (the universal IDC command lifecycle envelope):

    {
      "version": 2,
      "taints":  [ {"kind": ..., "key": ..., "session_id": ..., "fields": {...}}, ... ],
      "commands": [
        {
          "session_id":   "S1",              # the session that owns this command obligation
          "command":      "think",           # one of idc_command_contract.COMMANDS
          "state":        "active",          # "active" (open) → "finished" (closed)
          "plugin_version": "4.1.0",         # the running plugin version that opened the record
          "args_sha256":  "<64-lowercase-hex>",  # digest of the raw arg text (never the text itself)
          "source":       "user",            # command_source (user | plugin | ...)
          "closeout":     null               # null while active; the validated terminal envelope once finished
        }
      ]
    }

BACKWARD COMPATIBILITY. A v1 file — `{"version": 1, "taints": [...]}` with no `commands` — is read
tolerantly and normalized to the v2 shape on read (see `read_state`); it is only rewritten with
`version: 2` on the next write. Every write preserves BOTH arrays: a taint write never drops
`commands`, and a command write never drops `taints`. The finished-command history is capped
(`_MAX_FINISHED`, newest-finish order) while an active record is NEVER pruned.

TAINT KINDS (at minimum; a taint's identity is the (kind, key) pair):
  - `unfiled_findings`         — reviewer nits/deferrals not yet routed to the board (drop A/B).
  - `mid_finish:<item>`        — the finish tail STARTED closing <item> but has not completed it.
  - `recirc_checkpoint:<ticket>` — the recirculator checkpointed <ticket> mid-drain (drop F).
A taint is set when the deterministic action STARTS and cleared **only when that action COMPLETES**
— never by an LLM, never speculatively.

INVARIANT #1 — A STALE LEDGER MUST NEVER FALSELY BLOCK A CLEAN BOARD. The ledger is a *hint*; the
board + `idc_autorun_drain.py` (`recirc_inbox:` / `unplanned_considerations:` counts + the `drain:`
verdict + its exit code) are GROUND TRUTH. Two independent defenses enforce this, and a consumer
(the Stop gate) MUST rely on the second:
  1. Session scoping. Every taint carries the `session_id` that created it. `pending_taints(cwd,
     session_id=X)` returns only the obligations session X is responsible for — taints created by X,
     plus unattributed (session_id=None) ones. A DEAD prior session's leftover taint (a crash
     mid-finish that never cleared) is that session's business, not X's, so it is not X's obligation
     and cannot block X. (The unscoped `pending_taints(cwd)` returns the full hint set — for
     cross-session recovery/inspection by Stage C, not for gating a stop.)
  2. Ground-truth cross-check. Even for a taint scoped to the CURRENT session, the Stop gate blocks
     only when the ledger hint AND the board/drain agree work remains. The ledger alone never
     blocks; a clean `drain: complete` (exit 0) wins over any stale taint.

FAIL MODES. Reads are TOLERANT: a missing or corrupt ledger reads as EMPTY and never throws — a
corrupt ledger must not brick a gate (`read_taints` / `pending_taints`). Writes are ATOMIC
(temp-file + os.replace, so a concurrent reader never sees a half-written file), SERIALIZED across
concurrent writers by an advisory lock (`_write_lock`) so no taint is lost to a read-modify-write
race, and BEST-EFFORT: a write (or a lock) that fails warns/degrades rather than raising, so
recording a taint can never break the user's command (a post-hoc observer never fails-closed). Writes are REPO-GATED — a no-op
outside an IDC-governed repo (reuse `idc_hook_lib.is_governed_repo`) so a non-IDC repo on the
machine is never littered with a state file.

IDC_HOOKS_OBSERVE_ONLY. Honored at the GATE layer (the Stop/SubagentStop gate downgrades block→warn
via idc_hook_lib), NOT here: the ledger deliberately keeps RECORDING taints under observe-only,
because the whole point of the observe-first rollout is to SEE which obligations would have accrued.
Suppressing the record would blind the very observation observe-only exists to collect.

DRAIN IS ALREADY TRUTHFUL — no change needed here (deliverable #3, confirmed by evidence). Stage B's
Stop gate reads `idc_autorun_drain.py`'s EXISTING line output — it always prints `recirc_inbox: N`,
`unplanned_considerations: M`, and `drain: <verdict>`, and exits with a distinct code
(0 complete/continue · 2 unknown · 3 rate-limited · 4 recirc-pending) — plus this ledger's
`mid_finish` / `unfiled_findings` taints. That is a single drain call autorun already makes: NO new
board GraphQL, and NO `--json` mode is required (the line format is stable and pinned by
tests/smoke/governance/drain-recirc-pending.sh). The fixpoint math + exit-code contract (Phase 0)
are untouched.

USAGE (import — the primary path, for hooks/scripts):
    import idc_ledger
    idc_ledger.set_taint(cwd, "mid_finish", key=str(issue), session_id=sid)
    ...                                        # do the deterministic close
    idc_ledger.clear_taint(cwd, "mid_finish", key=str(issue))
    for t in idc_ledger.pending_taints(cwd, session_id=sid): ...

USAGE (CLI — for the scaffold's gitignore step, and the governance test):
    python3 idc_ledger.py --cwd <repo> path
    python3 idc_ledger.py --cwd <repo> set   --kind mid_finish --key 42 --session S1 [--field k=v]
    python3 idc_ledger.py --cwd <repo> clear --kind mid_finish --key 42
    python3 idc_ledger.py --cwd <repo> pending [--session S1]   # one `kind` or `kind:key` per line
    python3 idc_ledger.py --cwd <repo> ensure-gitignore         # additive, idempotent
"""
import argparse
import contextlib
import json
import os
import sys
import tempfile

# Same-dir import: idc_ledger lives beside idc_hook_lib in scripts/hooks/, so when run as a script
# (sys.path[0] == this dir) or imported by a hook that put this dir on sys.path, this resolves.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, defined once, shared)

LEDGER_FILENAME = ".idc-session-state.json"
# The scaffold ignores the state file AND its sidecar write-lock (`.idc-session-state.json.lock`)
# with ONE glob line — in gitignore `*` matches the empty string, so it still ignores the file itself.
GITIGNORE_LINE = LEDGER_FILENAME + "*"
# v2 (Task 2 — command integrity): the state file now carries a `commands` array (the universal IDC
# command lifecycle envelope) ALONGSIDE the v1 `taints`. v1 files are read tolerantly and normalized
# to v2 on read (see read_state); a v1 file is only rewritten with `version: 2` when the next write
# happens. Every write preserves BOTH arrays — a taint write never drops commands, and vice versa.
_LEDGER_VERSION = 2
# Command lifecycle record states + the finished-history cap (never prunes an active record).
_CMD_ACTIVE = "active"
_CMD_FINISHED = "finished"
_MAX_FINISHED = 20

try:
    import fcntl  # POSIX advisory file locks (macOS/Linux — IDC's platforms)
except ImportError:  # pragma: no cover - non-POSIX fallback
    fcntl = None


@contextlib.contextmanager
def _write_lock(cwd):
    """Serialize the ledger's read-modify-write across concurrent hook/script processes.

    set_taint/clear_taint READ the whole ledger, MODIFY it, then atomically REPLACE the file. Two
    processes recording DIFFERENT taints at the same time would each read the same old snapshot and
    the last os.replace would win — silently dropping the other's taint. A dropped taint is a dropped
    obligation, exactly the "loop lies about being done" failure Phase 3 exists to prevent. An
    exclusive advisory lock on a STABLE sidecar `.idc-session-state.json.lock` (we lock a sidecar,
    not the ledger itself, because os.replace orphans a lock held on the renamed inode) makes the
    read-modify-write atomic with respect to other writers.

    BEST-EFFORT (a post-hoc observer must never fail-closed): if fcntl is unavailable or the lock
    cannot be taken, proceed UNLOCKED rather than break the caller's command."""
    if fcntl is None:
        yield
        return
    fh = None
    try:
        fh = open(ledger_path(cwd) + ".lock", "w", encoding="utf-8")
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    except OSError:
        if fh is not None:
            try:
                fh.close()
            except OSError:
                pass
            fh = None
    try:
        yield
    finally:
        if fh is not None:
            try:
                fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            try:
                fh.close()
            except OSError:
                pass


# ── paths ──────────────────────────────────────────────────────────────────────────────────────────
def ledger_path(cwd):
    """The `.idc-session-state.json` path at the governed workspace root `cwd`."""
    return os.path.join(cwd or ".", LEDGER_FILENAME)


# ── tolerant read ────────────────────────────────────────────────────────────────────────────────
def _read_raw(cwd):
    """The raw ledger dict (both `taints` and `commands`). TOLERANT: a missing or corrupt ledger
    reads as an EMPTY dict and NEVER throws — a corrupt ledger must not brick a gate. The ONE decode
    point both the v1 taint readers and the v2 command readers share, so tolerance is defined once."""
    try:
        with open(ledger_path(cwd), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def read_taints(cwd):
    """Every taint dict currently in the ledger (a list). TOLERANT: a missing or corrupt ledger
    reads as an EMPTY list and NEVER throws — a corrupt ledger must not brick a gate."""
    taints = _read_raw(cwd).get("taints", [])
    if not isinstance(taints, list):
        return []
    return [t for t in taints if isinstance(t, dict) and t.get("kind")]


def _read_commands(cwd):
    """Every well-formed command lifecycle record currently in the ledger (a list). TOLERANT: a
    missing/corrupt ledger — or a v1 file with no `commands` key — reads as EMPTY, never throws. A
    record is well-formed iff it carries a session_id and a command (the identity a gate keys on)."""
    cmds = _read_raw(cwd).get("commands", [])
    if not isinstance(cmds, list):
        return []
    return [c for c in cmds if isinstance(c, dict) and c.get("session_id") and c.get("command")]


def read_state(cwd):
    """The whole ledger as a normalized v2 dict: {'version': 2, 'taints': [...], 'commands': [...]}.
    TOLERANT. A v1 file (`{'version': 1, 'taints': [...]}`) is normalized in-memory to v2 with an
    empty `commands` list — it is NOT rewritten on disk until the next write, so a read never mutates
    the file."""
    return {"version": _LEDGER_VERSION, "taints": read_taints(cwd), "commands": _read_commands(cwd)}


def pending_taints(cwd, session_id=None):
    """The pending taints (invariant #1 scoping).

    session_id=None → the FULL hint set (every taint) — cross-session recovery/inspection, NOT a
    gate signal. session_id=X → only the obligations session X is responsible for: taints created
    by X plus unattributed (session_id=None) ones, so a dead prior session's leftover taint is never
    X's obligation and cannot falsely block X's clean board."""
    taints = read_taints(cwd)
    if session_id is None:
        return taints
    return [t for t in taints if t.get("session_id") in (session_id, None)]


# ── atomic, best-effort write ────────────────────────────────────────────────────────────────────
def _atomic_write_state(cwd, taints, commands):
    """Write the WHOLE ledger (both arrays) atomically (temp-file + os.replace). BEST-EFFORT for the
    caller's control flow — an OSError WARNS and RETURNS (never raises), so recording state can never
    break the user's command — but the outcome is SURFACED as a bool: True iff the state actually
    PERSISTED to disk, False if the temp-file create / write / os.replace failed. A caller that reports
    a record as opened (the entry gate, command_start) MUST check this so a swallowed write is never
    mistaken for a persisted one (Fix 2). This is the single write door — every taint write AND every
    command write funnels through here, so neither array can ever silently drop the other (the v1→v2
    co-existence invariant)."""
    path = ledger_path(cwd)
    d = os.path.dirname(path) or "."
    payload = {"version": _LEDGER_VERSION, "commands": commands, "taints": taints}
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".idc-ledger.", suffix=".tmp")
    except OSError as e:
        idc_hook_lib.warn(f"ledger: cannot create temp file in {d}: {e}")
        return False
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as e:
        idc_hook_lib.warn(f"ledger: atomic write to {path} failed: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False
    return True


def _atomic_write(cwd, taints):
    """Write `taints` while PRESERVING the existing `commands` array (the v1 taint writers' door).
    Called under `_write_lock`, so the `_read_commands` read-back is race-free vs concurrent writers.
    Returns the single-write-door's persisted bool (taint writers are best-effort and ignore it; the
    command writers propagate it)."""
    return _atomic_write_state(cwd, taints, _read_commands(cwd))


# ── the write API (deterministic callers only) ──────────────────────────────────────────────────
def set_taint(cwd, kind, key=None, session_id=None, **fields):
    """Add or update the (kind, key) taint. REPO-GATED: a silent no-op outside a governed repo.
    Upserts by identity (kind, key) so a re-set never duplicates. Carries the creating session_id
    (invariant #1 scoping) and any extra `fields`. Recovers a corrupt/missing file (tolerant read
    → rewrite)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return
    key = None if key is None else str(key)
    if session_id is None:
        session_id = os.environ.get("IDC_SESSION_ID") or None
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost taints)
        taints = [t for t in read_taints(cwd) if not (t.get("kind") == kind and t.get("key") == key)]
        taints.append({"kind": kind, "key": key, "session_id": session_id, "fields": dict(fields)})
        _atomic_write(cwd, taints)


def clear_taint(cwd, kind, key=None):
    """Remove the (kind, key) taint — called ONLY when the deterministic action COMPLETES.
    REPO-GATED (no-op outside a governed repo). Idempotent: clearing an absent taint is a no-op."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return
    key = None if key is None else str(key)
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost taints)
        before = read_taints(cwd)
        after = [t for t in before if not (t.get("kind") == kind and t.get("key") == key)]
        if len(after) != len(before):
            _atomic_write(cwd, after)


# ── the command lifecycle envelope (v2 — Task 2, command integrity) ───────────────────────────────
# A `commands[]` record is the durable obligation that a governed `/idc:*` command was ENTERED and
# must be CLOSED with a valid terminal status. Its identity is the (session_id, command) pair. The
# deterministic entry gate opens it (command_start); the deterministic command tail closes it
# (command_finish); the Stop closeout gate reads active_commands to refuse an un-closed command.
def _prune_finished(commands):
    """Cap the finished-record history at `_MAX_FINISHED`, newest write order, NEVER pruning an
    active record. Active records are always retained in place; only the OLDEST finished records past
    the cap are dropped."""
    active = [c for c in commands if c.get("state") == _CMD_ACTIVE]
    finished = [c for c in commands if c.get("state") != _CMD_ACTIVE]
    if len(finished) > _MAX_FINISHED:
        finished = finished[-_MAX_FINISHED:]
    return active + finished


def command_start(cwd, session_id, command, plugin_version, args_sha256, source,
                  intake_manifest=None, intake_units=None):
    """Atomic UPSERT of the active command record by (session_id, command) — never duplicates an
    active record (a re-entry of the same command in the same session updates the one record in
    place). REPO-GATED: a silent no-op outside a governed repo (returns `{}`). Preserves the taint
    array. Returns the record dict ONLY when the write actually PERSISTED; returns None when the
    ledger write FAILED (Fix 2) — a caller must never report an obligation as opened on a failed
    write, or the Stop gate would try to enforce a closeout for a record that does not exist.

    An EMPTY/blank session identity is REFUSED fail-closed (returns None, no write): a runtime that
    fires no Claude UserPromptExpansion (Codex/Pi) can leave `$CLAUDE_CODE_SESSION_ID` empty, and an
    anonymous record keyed on session="" would let two session-less runs collide on (session="",
    command) — finishing or overwriting each other's obligation. The identity is load-bearing, so a
    blank one is never stored (finding 5)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return {}
    if not str(session_id).strip():
        return None
    session_id = str(session_id)
    command = str(command)
    rec = {
        "session_id": session_id,
        "command": command,
        "state": _CMD_ACTIVE,
        "plugin_version": plugin_version or "",
        "args_sha256": args_sha256 or "",
        "source": source or "",
        "closeout": None,
    }
    # Durable intake-mode marker (finding 2): a Think run started with `--doc/--unit` records its
    # intake manifest (repo-relative) + selected units on the record, so the Think closeout re-verifies
    # exact-once coverage from the RECORD — never inferable only from caller-supplied finish input.
    if intake_manifest:
        rec["intake_manifest"] = str(intake_manifest)
        rec["intake_units"] = [str(u) for u in (intake_units or [])]
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers (no lost records)
        commands = _read_commands(cwd)
        replaced = False
        for i, c in enumerate(commands):
            if (c.get("session_id") == session_id and c.get("command") == command
                    and c.get("state") == _CMD_ACTIVE):
                # MONOTONIC intake marker (round-2 F3-r2): a re-start of an ACTIVE intake-mode record
                # can never silently shed its coverage obligation. If the existing active record
                # carries an intake manifest and this re-start supplied none, carry the prior marker
                # FORWARD onto the upsert — so a plain re-entry of the same command cannot make an
                # intake-mode run look non-intake and slip a dropped-unit close past the coverage
                # check. (A re-start that DOES supply its own intake ref replaces it as usual.)
                if not intake_manifest and c.get("intake_manifest"):
                    rec["intake_manifest"] = c.get("intake_manifest")
                    rec["intake_units"] = list(c.get("intake_units") or [])
                commands[i] = rec
                replaced = True
                break
        if not replaced:
            commands.append(rec)
        persisted = _atomic_write_state(cwd, read_taints(cwd), _prune_finished(commands))
    return rec if persisted else None


def command_finish(cwd, session_id, command, status, evidence):
    """Finish ONLY an existing ACTIVE record owned by `session_id` — a foreign session cannot finish
    or inherit another session's record, and a missing active record is a no-op. Records the terminal
    `status` + normalized `evidence` in the record's `closeout` and flips its state to finished.
    REPO-GATED (no-op outside a governed repo). Returns the finished record dict, or None when there
    was no matching active record owned by this session OR the closeout write did not PERSIST (Fix 2)
    — either way the caller surfaces the non-close as a failure rather than reporting a false close.

    An EMPTY/blank session identity is REFUSED fail-closed (returns None): a session="" finish could
    otherwise close another anonymous session's record (finding 5)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return None
    if not str(session_id).strip():
        return None
    session_id = str(session_id)
    command = str(command)
    with _write_lock(cwd):  # read-modify-write must be atomic vs concurrent writers
        commands = _read_commands(cwd)
        target = None
        for c in commands:
            if (c.get("session_id") == session_id and c.get("command") == command
                    and c.get("state") == _CMD_ACTIVE):
                target = c
                break
        if target is None:
            return None
        target["state"] = _CMD_FINISHED
        target["closeout"] = {"status": status, "evidence": evidence}
        # Move the just-finished record to the NEWEST write position so the finished-history cap
        # (_prune_finished keeps the last _MAX_FINISHED in write order) drops the OLDEST finished
        # record — never this one. Finishing in place would leave an early-started record at the
        # front of the list, where the cap would prune it as the "oldest" even though it just closed.
        commands.remove(target)
        commands.append(target)
        if not _atomic_write_state(cwd, read_taints(cwd), _prune_finished(commands)):
            return None  # the close did not persist → do not report a false close (Fix 2)
    return target


def active_commands(cwd, session_id=None):
    """The state=active command records, optionally scoped to one session. TOLERANT (a corrupt/missing
    ledger reads as empty). session_id=None → every active record; session_id=X → only X's active
    records, so the Stop closeout gate never traps an unrelated session with another's open command."""
    active = [c for c in _read_commands(cwd) if c.get("state") == _CMD_ACTIVE]
    if session_id is None:
        return active
    return [c for c in active if c.get("session_id") == str(session_id)]


# ── the gitignore scaffold hook (idempotent, non-destructive) ────────────────────────────────────
def ensure_gitignored(repo_root):
    """Ensure the repo-root `.gitignore` contains `.idc-session-state.json`, idempotently and
    NON-DESTRUCTIVELY (create the file if absent; otherwise APPEND the line only if missing — never
    rewrite or reorder an operator's existing lines). REPO-GATED: a no-op outside a governed repo,
    so a stray call never creates a `.gitignore` in a non-IDC dir. Returns True iff the line is
    present afterward."""
    if not idc_hook_lib.is_governed_repo(repo_root):
        return False
    gi = os.path.join(repo_root, ".gitignore")
    try:
        existing = ""
        if os.path.isfile(gi):
            with open(gi, encoding="utf-8") as fh:
                existing = fh.read()
        # Whole-line presence check (ignore surrounding whitespace; tolerate no trailing newline).
        if any(ln.strip() == GITIGNORE_LINE for ln in existing.splitlines()):
            return True
        with open(gi, "a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            if not existing:
                fh.write("# IDC obligations ledger — transient per-session state, never committed.\n")
            elif not existing.rstrip("\n").endswith(("#", ":")):
                # Separate our entry from prior operator content with one comment for provenance.
                fh.write("# IDC obligations ledger (per-session state; do not commit)\n")
            fh.write(GITIGNORE_LINE + "\n")
        return True
    except OSError as e:
        idc_hook_lib.warn(f"ledger: could not ensure .gitignore in {repo_root}: {e}")
        return False


# ── CLI (scaffold gitignore step + governance test driver; NOT an LLM-facing surface) ────────────
def _fmt(t):
    """One pending taint as a grep-friendly line: `kind` or `kind:key`."""
    return f"{t['kind']}:{t['key']}" if t.get("key") is not None else str(t["kind"])


def main(argv=None):
    ap = argparse.ArgumentParser(description="IDC per-session obligations ledger (scripts/hooks only)")
    ap.add_argument("--cwd", default=".", help="governed workspace root (default: cwd)")
    sub = ap.add_subparsers(dest="op", required=True)

    sub.add_parser("path", help="print the ledger file path")
    sub.add_parser("ensure-gitignore", help="idempotently add the ledger to the repo-root .gitignore")

    sp = sub.add_parser("set", help="add/update a taint")
    sp.add_argument("--kind", required=True)
    sp.add_argument("--key", default=None)
    sp.add_argument("--session", default=None)
    sp.add_argument("--field", action="append", default=[], metavar="k=v",
                    help="extra field (repeatable)")

    cp = sub.add_parser("clear", help="remove a taint (deterministic action completed)")
    cp.add_argument("--kind", required=True)
    cp.add_argument("--key", default=None)

    pp = sub.add_parser("pending", help="list pending taints (one `kind` or `kind:key` per line)")
    pp.add_argument("--session", default=None, help="scope to this session (invariant #1)")

    args = ap.parse_args(argv)
    cwd = args.cwd

    if args.op == "path":
        print(ledger_path(cwd))
    elif args.op == "ensure-gitignore":
        ensure_gitignored(cwd)
    elif args.op == "set":
        fields = {}
        for kv in args.field:
            k, _, v = kv.partition("=")
            fields[k] = v
        set_taint(cwd, args.kind, key=args.key, session_id=args.session, **fields)
    elif args.op == "clear":
        clear_taint(cwd, args.kind, key=args.key)
    elif args.op == "pending":
        for t in pending_taints(cwd, session_id=args.session):
            print(_fmt(t))
    return 0


if __name__ == "__main__":
    sys.exit(main())
