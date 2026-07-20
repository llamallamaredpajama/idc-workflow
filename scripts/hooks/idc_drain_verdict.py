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

    {"version": 2, "verdict": "recirc-pending", "exit": 4, "session_id": "<sid>",
     "gates": ["coherence", "live"], "ts": 1720137600.0}

`verdict` is the drain's verdict token (`complete` · `continue` · `recirc-pending` · `unknown` ·
`rate-limited` · `board-read-error`); `exit` is its Phase-0 exit code (0 · 2 · 3 · 4); `session_id`
is the drain session that wrote it; `gates` names the wave-close gates that ACTUALLY RAN on the pass
that wrote it (see below); `ts` is a POSIX timestamp for staleness (`time.time()` — a python script
MAY use it; only workflow-script sandboxes forbid it).

A `complete` IS NOT SELF-PROVING — `gates` IS PART OF THE VERDICT (the completion-honesty fix). The
wave-close gates (`--coherence`, `--live`) are OPT-IN FLAGS, so the drain prints and persists exactly
the same `complete` whether it checked the board against reality or checked nothing at all. Several
sanctioned callers legitimately pass no gate flags — `idc:idc-build` Phase 0 runs the drain with only
`--width` to size the ready frontier — and on the github backend the Stop gate has no backstop: it
cannot re-run the drain (the zero-GraphQL constraint), so it believes this file. Combined with
last-write-wins, an ungated frontier query could overwrite a properly gated `complete` and launder an
unchecked pipe into a clean bill of health — the exact false-clean class this sidecar exists to close.
So the WRITER records which gates ran, and a READER asking "is this proof of completion?" must use
`proves_complete()` rather than comparing the token itself. A record with NO `gates` key (a version-1
file written before this fix) reads as UNKNOWN gates — explicitly NOT proof, never a crash.

WHY `coherence` + `live` ARE THE REQUIRED SET (`COMPLETION_HONESTY_GATES`) and `acceptance` is not:
both run on BOTH backends, so requiring them is satisfiable everywhere the drain persists. The
acceptance check is filesystem-only (the github lane has no local TRACKER.md; its wave-close
acceptance runs inside `idc:idc-build` Phase 4), so requiring it would make every github `complete`
unprovable. It is still RECORDED when it runs, so a reader that wants it can ask.

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
    idc_drain_verdict.write_verdict(root, "recirc-pending", 4, sid, gates=["coherence", "live"])
    v = idc_drain_verdict.current_verdict(cwd, session_id=sid)         # the Stop gate (github)
    if idc_drain_verdict.proves_complete(v):                           # NOT `v["verdict"] == "complete"`
        ...

USAGE (CLI — the scaffold's gitignore step, and the governance test):
    python3 idc_drain_verdict.py --cwd <repo> path
    python3 idc_drain_verdict.py --cwd <repo> write --verdict recirc-pending --exit 4 --session S1 \
        [--gates coherence,live] [--ts N]
    python3 idc_drain_verdict.py --cwd <repo> read [--session S1]      # prints the JSON, or nothing
    python3 idc_drain_verdict.py --cwd <repo> ensure-gitignore         # additive, idempotent
"""
import argparse
import json
import os
import sys
import time

# Same-dir import: idc_drain_verdict lives beside idc_hook_lib in scripts/hooks/, so when run as a
# script (sys.path[0] == this dir) or imported by a hook that put this dir on sys.path, this resolves.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib  # noqa: E402  (is_governed_repo — the ONE repo-gate, defined once, shared)

VERDICT_FILENAME = ".idc-drain-verdict.json"
# The scaffold ignores the file with ONE glob line (mirrors the ledger's `.idc-session-state.json*`) —
# `*` matches the empty string so the file itself is ignored, and any future sidecar too.
GITIGNORE_LINE = VERDICT_FILENAME + "*"
_VERDICT_VERSION = 2
# The wave-close gates a `complete` must have RUN behind it before any reader may treat it as proof
# that the pipe is finished (`proves_complete`). Both run on BOTH backends, which is precisely why
# they — and not the filesystem-only `acceptance` — are the required set; see the module docstring.
COMPLETION_HONESTY_GATES = ("coherence", "live")
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


def gates_ran(verdict):
    """The set of wave-close gates that ACTUALLY RAN on the pass that wrote `verdict`, or None when the
    record does not say (a version-1 file written before gates were recorded — UNKNOWN, not empty).

    The None/empty distinction is the whole point and must not be collapsed: an empty set is a positive
    statement ("this pass ran no gates"), None is an absence of evidence. Both are non-proof, but only
    one of them is a fact. TOLERANT: a malformed `gates` value (not a list of strings) reads as None."""
    if not isinstance(verdict, dict) or "gates" not in verdict:
        return None
    raw = verdict.get("gates")
    if not isinstance(raw, list) or any(not isinstance(g, str) for g in raw):
        return None
    return {g for g in raw if g}


def proves_complete(verdict, required=COMPLETION_HONESTY_GATES):
    """True iff `verdict` is PROOF that the pipe reached an honest whole-pipe fixpoint.

    THE ONE READER-SIDE DOOR — use this instead of `verdict.get("verdict") == "complete"`. The token
    alone says only that the build lane was empty on some pass; it says nothing about whether the
    wave-close gates that make `complete` mean "finished" were ever asked. Proof requires BOTH:
      * the token is exactly `complete`, AND
      * every gate in `required` is named in the record's `gates` (unknown gates ⇒ NOT proof).
    Everything short of that is "not proven complete", which every caller already knows how to handle —
    the Stop gate defers (warn, allow the stop, but leave the orchestrator marker in place) and the
    command-contract validator refuses the `complete` claim. Neither invents a new failure mode."""
    if not isinstance(verdict, dict) or verdict.get("verdict") != "complete":
        return False
    ran = gates_ran(verdict)
    if ran is None:
        return False
    return set(required) <= ran


# ── atomic, best-effort write ────────────────────────────────────────────────────────────────────
def _atomic_write(cwd, payload):
    """Write the verdict atomically via the shared sidecar writer. BEST-EFFORT: a failure warns and
    returns (never raises) so persisting a verdict can never break the drain."""
    idc_hook_lib.atomic_write_json(verdict_path(cwd), payload,
                                   prefix=".idc-drain-verdict.", label="drain-verdict")


def write_verdict(cwd, verdict, exit_code, session_id=None, ts=None, gates=()):
    """Persist THIS drain pass's verdict. REPO-GATED: a silent no-op outside a governed repo. Overwrites
    the whole file (last-write-wins) so the newest pass is always authoritative. `session_id` scopes it
    to the writing session (so only that session's stop can be gated by it); `ts` defaults to now (a
    POSIX timestamp). BEST-EFFORT via `_atomic_write` — never raises, never touches the drain's
    exit-code/stdout contract (this is called just before the drain exits).

    `gates` names the wave-close gates that ACTUALLY RAN on this pass (not the flags that were passed —
    a flag whose checker is absent or inapplicable did not run). It defaults to EMPTY, so a caller that
    forgets it records the honest "no gates ran" and its `complete` is correctly non-proof: the failure
    mode of an omission is a deferred stop, never a laundered one."""
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
        "gates": sorted({str(g) for g in (gates or ()) if str(g)}),
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
    return idc_hook_lib.ensure_gitignored(
        repo_root, GITIGNORE_LINE, label="drain-verdict",
        created_comment="# IDC drain verdict — transient per-session state, never committed.",
        appended_comment="# IDC drain verdict (per-session state; do not commit)")


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
    wp.add_argument("--gates", default="",
                    help="comma-separated wave-close gates that RAN on this pass (e.g. coherence,live); "
                         "empty records an ungated pass, whose `complete` is not proof of completion")
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
        write_verdict(cwd, args.verdict, args.exit_code, session_id=args.session, ts=args.ts,
                      gates=[g.strip() for g in args.gates.split(",") if g.strip()])
    elif args.op == "read":
        v = current_verdict(cwd, args.session) if args.session else read_verdict(cwd)
        if v is not None:
            print(json.dumps(v, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
