#!/usr/bin/env python3
"""idc_ledger.py — the per-session obligations ledger (v4 Phase 3, plan §3.4).

WHAT THIS IS. A tiny, dependency-free state store that DETERMINISTIC hooks/scripts — **never the
LLM** — use to record and clear *obligation taints* accrued during a session, so later gates
(Phase 3's Stop / SubagentStop) can ask "does this session still owe work?" WITHOUT a board scan.
It is the file-backed-labels half of Omnigent's stateful-policy pattern; the gates are the policy.

THE FILE. One JSON file, `.idc-session-state.json`, at the **governed workspace root**
(`ledger_path(cwd)`). It is transient working state, gitignored via the scaffold
(`ensure_gitignored()`, wired into idc_init_scaffold.sh + /idc:update) so a clean autorun/build exit
never leaves committed litter. Shape:

    {"version": 1, "taints": [ {"kind": ..., "key": ..., "session_id": ..., "fields": {...}}, ... ]}

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
_LEDGER_VERSION = 1

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
def read_taints(cwd):
    """Every taint dict currently in the ledger (a list). TOLERANT: a missing or corrupt ledger
    reads as an EMPTY list and NEVER throws — a corrupt ledger must not brick a gate."""
    try:
        with open(ledger_path(cwd), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return []
    if not isinstance(data, dict):
        return []
    taints = data.get("taints", [])
    if not isinstance(taints, list):
        return []
    return [t for t in taints if isinstance(t, dict) and t.get("kind")]


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
def _atomic_write(cwd, taints):
    """Write the ledger atomically (temp-file + os.replace). BEST-EFFORT: an OSError warns and
    returns (never raises) so recording a taint can never break the user's command."""
    path = ledger_path(cwd)
    d = os.path.dirname(path) or "."
    payload = {"version": _LEDGER_VERSION, "taints": taints}
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".idc-ledger.", suffix=".tmp")
    except OSError as e:
        idc_hook_lib.warn(f"ledger: cannot create temp file in {d}: {e}")
        return
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
