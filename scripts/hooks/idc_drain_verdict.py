#!/usr/bin/env python3
"""idc_drain_verdict.py — the persisted drain verdict (v4 Phase 3 Stage E2, plan §3.4).

WHAT THIS IS. A tiny, dependency-free sidecar to the obligations ledger. Each time
`idc_autorun_drain.py` runs (any backend, any pass of the drain loop), it records its LAST verdict —
`{verdict, exit, session_id, ts}` — to a local, gitignored file at the governed workspace root. The
Stop fixpoint gate (`idc_stop_fixpoint_gate.py`) reads THIS file on the GITHUB backend instead of
re-running the drain live, so the github stop path stays at **ZERO new GraphQL**: the block conjunct
(the board) comes from the persisted verdict, not a fresh board scan. On the FILESYSTEM backend the
drain is a cheap local read, so the gate keeps re-running it live (this file is written there too, but
the filesystem gate ignores it — the persist is purely additive and never changes filesystem behavior).

THE FILE. One JSON file, `.idc-drain-verdict.json`, at the **governed workspace root**
(`verdict_path(cwd)`). Transient working state, gitignored via the scaffold + /idc:update
(`ensure_gitignored()`), so a clean autorun/build exit never leaves committed litter. Shape:

    {"version": 1, "verdict": "recirc-pending", "exit": 4, "session_id": "<sid>", "ts": 1720137600.0}

`verdict` is the drain's verdict token (`complete` · `continue` · `recirc-pending` · `unknown` ·
`rate-limited` · `board-read-error`); `exit` is its Phase-0 exit code (0 · 2 · 3 · 4); `session_id`
is the drain session that wrote it; `ts` is a POSIX timestamp for staleness (`time.time()` — a python
script MAY use it; only workflow-script sandboxes forbid it).

INVARIANT — ONLY THIS SESSION'S OWN VERDICT GATES ITS OWN STOP (session scoping, mirrors the ledger's
invariant #1 defense 1). `current_verdict(cwd, session_id=X)` returns the persisted verdict ONLY when
its `session_id` EQUALS X. A DIFFERENT (foreign / dead) session's verdict is NEVER returned, so it can
never gate X's stop. No persisted verdict for X (absent file, or a foreign one) → None → the gate
DEFERS (warn + allow); you can only gate on data you have, never a guess.

LAST-WRITE-WINS FRESHNESS. Every drain pass overwrites the file, INCLUDING the final `complete`, so a
stale `recirc-pending` from an early pass can never outlive a real completion: the last pass before
the stop is authoritative. `ts` adds a defensive staleness discard — a verdict older than
`_STALE_AFTER_S` (a drain→stop window is seconds; the bound is 4+ orders of magnitude of slack) is
treated as clearly-abandoned and returned as None (defer), so a day-old file from a since-recreated
session id can't gate. Session scope + last-write-wins is the load-bearing correctness; `ts` is belt.

FAIL MODES (mirror the ledger). Reads are TOLERANT: a missing or corrupt file reads as None and never
throws — a corrupt verdict must not brick the gate. Writes are ATOMIC (temp-file + os.replace, so a
concurrent reader never sees a half-written file) and BEST-EFFORT: a write that fails warns/degrades
rather than raising, so persisting a verdict can NEVER break the drain (persistence is additive — it
must not touch the drain's exit-code contract or stdout). Writes are REPO-GATED — a no-op outside an
IDC-governed repo (reuse `idc_hook_lib.is_governed_repo`) so a non-IDC repo is never littered.

USAGE (import — hooks/scripts):
    import idc_drain_verdict
    idc_drain_verdict.write_verdict(root, "recirc-pending", 4, sid)   # the drain, each pass
    v = idc_drain_verdict.current_verdict(cwd, session_id=sid)         # the Stop gate (github)

USAGE (CLI — the scaffold's gitignore step, and the governance test):
    python3 idc_drain_verdict.py --cwd <repo> path
    python3 idc_drain_verdict.py --cwd <repo> write --verdict recirc-pending --exit 4 --session S1 [--ts N]
    python3 idc_drain_verdict.py --cwd <repo> read [--session S1]      # prints the JSON, or nothing
    python3 idc_drain_verdict.py --cwd <repo> ensure-gitignore         # additive, idempotent
"""
import argparse
import json
import os
import sys
import tempfile
import time

# Same-dir import: idc_drain_verdict lives beside idc_hook_lib in scripts/hooks/, so when run as a
# script (sys.path[0] == this dir) or imported by a hook that put this dir on sys.path, this resolves.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, defined once, shared)

VERDICT_FILENAME = ".idc-drain-verdict.json"
# The scaffold ignores the file with ONE glob line (mirrors the ledger's `.idc-session-state.json*`) —
# `*` matches the empty string so the file itself is ignored, and any future sidecar too.
GITIGNORE_LINE = VERDICT_FILENAME + "*"
_VERDICT_VERSION = 1
# A persisted verdict older than this is treated as clearly-abandoned (None → the gate defers). A live
# drain→stop window is seconds; 24h is deliberately vast slack — its only job is to distrust a file
# from a since-gone session id, never to false-defer a real run.
_STALE_AFTER_S = 24 * 60 * 60


# ── paths ──────────────────────────────────────────────────────────────────────────────────────────
def verdict_path(cwd):
    """The `.idc-drain-verdict.json` path at the governed workspace root `cwd`."""
    return os.path.join(cwd or ".", VERDICT_FILENAME)


# ── tolerant read ────────────────────────────────────────────────────────────────────────────────
def read_verdict(cwd):
    """The persisted verdict dict, or None. TOLERANT: a missing or corrupt file reads as None and
    NEVER throws — a corrupt verdict must not brick the gate. Returns None unless the payload is a
    dict carrying a non-empty `verdict`."""
    try:
        with open(verdict_path(cwd), encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not data.get("verdict"):
        return None
    return data


def current_verdict(cwd, session_id):
    """The persisted verdict for THIS session, or None (session scoping — invariant).

    Returns the verdict ONLY when session_id is truthy AND the persisted `session_id` EQUALS it AND the
    verdict is not clearly-stale (`ts` within `_STALE_AFTER_S`). A foreign-session verdict, an absent
    file, or an empty session_id → None, and the Stop gate then DEFERS (warn + allow) rather than guess.
    This is the ONLY consumer the github stop path uses; it reads the local file and NOTHING else (zero
    GraphQL)."""
    if not session_id:
        return None
    v = read_verdict(cwd)
    if v is None or v.get("session_id") != session_id:
        return None
    ts = v.get("ts")
    if isinstance(ts, (int, float)) and (time.time() - ts) > _STALE_AFTER_S:
        return None
    return v


# ── atomic, best-effort write ────────────────────────────────────────────────────────────────────
def _atomic_write(cwd, payload):
    """Write the verdict atomically (temp-file + os.replace). BEST-EFFORT: an OSError warns and
    returns (never raises) so persisting a verdict can never break the drain."""
    path = verdict_path(cwd)
    d = os.path.dirname(path) or "."
    try:
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".idc-drain-verdict.", suffix=".tmp")
    except OSError as e:
        idc_hook_lib.warn(f"drain-verdict: cannot create temp file in {d}: {e}")
        return
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except OSError as e:
        idc_hook_lib.warn(f"drain-verdict: atomic write to {path} failed: {e}")
        try:
            os.remove(tmp)
        except OSError:
            pass


def write_verdict(cwd, verdict, exit_code, session_id=None, ts=None):
    """Persist THIS drain pass's verdict. REPO-GATED: a silent no-op outside a governed repo. Overwrites
    the whole file (last-write-wins) so the newest pass is always authoritative. `session_id` scopes it
    to the writing session (so only that session's stop can be gated by it); `ts` defaults to now (a
    POSIX timestamp). BEST-EFFORT via `_atomic_write` — never raises, never touches the drain's
    exit-code/stdout contract (this is called just before the drain exits)."""
    if not idc_hook_lib.is_governed_repo(cwd):
        return
    # Self-heal the gitignore on write (idempotent, best-effort): the scaffold + /idc:update add the
    # ignore line, but a repo installed BEFORE Stage E2 could run autorun and `git add -A` the verdict
    # file before it ever updates. Ensuring it here means the very first persist can never leave
    # committed litter, regardless of install age or update ordering (MINOR-1, reviewer-E2).
    ensure_gitignored(cwd)
    payload = {
        "version": _VERDICT_VERSION,
        "verdict": verdict,
        "exit": exit_code,
        "session_id": session_id or None,
        "ts": float(ts) if ts is not None else time.time(),
    }
    _atomic_write(cwd, payload)


# ── the gitignore scaffold hook (idempotent, non-destructive) ────────────────────────────────────
def ensure_gitignored(repo_root):
    """Ensure the repo-root `.gitignore` contains `.idc-drain-verdict.json*`, idempotently and
    NON-DESTRUCTIVELY (create the file if absent; otherwise APPEND the line only if missing — never
    rewrite or reorder an operator's existing lines). REPO-GATED: a no-op outside a governed repo, so a
    stray call never creates a `.gitignore` in a non-IDC dir. Returns True iff the line is present
    afterward. Mirrors idc_ledger.ensure_gitignored exactly (parallel transient sidecar)."""
    if not idc_hook_lib.is_governed_repo(repo_root):
        return False
    gi = os.path.join(repo_root, ".gitignore")
    try:
        existing = ""
        if os.path.isfile(gi):
            with open(gi, encoding="utf-8") as fh:
                existing = fh.read()
        if any(ln.strip() == GITIGNORE_LINE for ln in existing.splitlines()):
            return True
        with open(gi, "a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            if not existing:
                fh.write("# IDC drain verdict — transient per-session state, never committed.\n")
            elif not existing.rstrip("\n").endswith(("#", ":")):
                fh.write("# IDC drain verdict (per-session state; do not commit)\n")
            fh.write(GITIGNORE_LINE + "\n")
        return True
    except OSError as e:
        idc_hook_lib.warn(f"drain-verdict: could not ensure .gitignore in {repo_root}: {e}")
        return False


# ── CLI (scaffold gitignore step + governance test driver; NOT an LLM-facing surface) ────────────
def main(argv=None):
    ap = argparse.ArgumentParser(description="IDC persisted drain verdict (scripts/hooks only)")
    ap.add_argument("--cwd", default=".", help="governed workspace root (default: cwd)")
    sub = ap.add_subparsers(dest="op", required=True)

    sub.add_parser("path", help="print the verdict file path")
    sub.add_parser("ensure-gitignore", help="idempotently add the verdict file to the repo-root .gitignore")

    wp = sub.add_parser("write", help="persist a verdict (the drain's job; exposed for tests)")
    wp.add_argument("--verdict", required=True)
    wp.add_argument("--exit", dest="exit_code", type=int, required=True)
    wp.add_argument("--session", default=None)
    wp.add_argument("--ts", type=float, default=None, help="POSIX timestamp override (staleness tests)")

    rp = sub.add_parser("read", help="print the persisted verdict JSON (session-scoped with --session)")
    rp.add_argument("--session", default=None,
                    help="scope to this session (prints only THIS session's fresh verdict)")

    args = ap.parse_args(argv)
    cwd = args.cwd

    if args.op == "path":
        print(verdict_path(cwd))
    elif args.op == "ensure-gitignore":
        ensure_gitignored(cwd)
    elif args.op == "write":
        write_verdict(cwd, args.verdict, args.exit_code, session_id=args.session, ts=args.ts)
    elif args.op == "read":
        v = current_verdict(cwd, args.session) if args.session else read_verdict(cwd)
        if v is not None:
            print(json.dumps(v, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
