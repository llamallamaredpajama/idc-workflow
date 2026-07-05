#!/usr/bin/env python3
"""idc_recirc_reconcile.py — the MAIN-SESSION recirculation closeout-or-checkpoint reconciliation
(v4 Phase 3 Stage E1, plan §3.2 drop F — the main-session / kill-safe path).

WHY THIS EXISTS (the hole Stage C left open). Stage C's `idc_recirc_closeout_gate.py` fires on
`SubagentStop` and checkpoints a recirculator **subagent** that dies mid-drain. But the PRIMARY
`/idc:recirculate` drain runs **in the main session** (`commands/autorun.md` invokes it no-args at
the top of the pipe; `agents/idc-recirculator.md`: "in-session there is no gate backstop") — and
**no `SubagentStop` fires for a main-session drain**. A **hard kill** of the main session fires no
hook at all. So a main-session drain that dies mid-way leaves still-open inbox tickets with **no
resume-checkpoint** → drop F is open for this path. This script closes it: a deterministic
reconciliation the drain loop runs at the **top of each autorun pass** (kill-recovery — the ONLY
path that survives a hard kill, because no hook fires) and at the **end of `/idc:recirculate`**.

WHAT IT GUARANTEES. Reconcile every still-open `Stage=Recirculation ∧ Status=Todo` inbox ticket
(board = ground truth) against the obligation ledger:
  * CHECKPOINT — for each open ticket that carries NO `recirc_checkpoint:<ticket>` taint yet, stamp a
    resume-breadcrumb comment (via the SANCTIONED tracker comment helper — never a raw board
    mutation) and set the taint. The taint IS the idempotence latch: an open ticket that ALREADY has
    the taint was checkpointed on an earlier pass, so it is skipped — repeated passes never spam
    duplicate comments (the reused `_fs_comment`/github commenter have no dedup of their own).
  * CLEAR — for each existing `recirc_checkpoint:<ticket>` taint whose ticket is NO LONGER in the
    open inbox (it was absorbed → Done, or parked → Blocked), clear the taint: the obligation is
    satisfied (this is the "action completed" clear branch). This clear is ticket-keyed and
    CROSS-SESSION on purpose (NOT `idc_recirc_closeout_gate._clear_session_checkpoints`, which is
    session-scoped) — kill-recovery must clear a DEAD prior session's stale checkpoint once its
    ticket is provably gone from the board, and clearing on proven-absence-from-the-board is always
    safe (the board is ground truth; the taint is only a breadcrumb).

SAFE-BIAS — OVER-ACT, NEVER UNDER-ACT (invariant #1 / drop-F). UNDER-checkpointing an open ticket IS
the state loss this exists to prevent; OVER-checkpointing is only a recoverable breadcrumb (the board
is ground truth, a re-drain is idempotent). So when the inbox CANNOT be read (`still_open is None` — a
missing/corrupt/locked tracker, or a failed board read), the reconciliation FAILS SAFE: it clears
NOTHING (a stale taint survives rather than being wiped) and stamps nothing (we don't know which
tickets), reports `reconcile: unknown`, and warns — a read failure must never look like "nothing
open" (that false-empty is the exact drop-F state loss). It NEVER treats None as an empty inbox.

TRANSCRIPT-LESS BY DESIGN (the crux). Stage C reconstructs dispositions from the subagent transcript
(`agent_transcript_path`). In the main-session / next-pass-after-kill shape there is **no such
transcript** available to a shelled script — a killed prior drain left no transcript handle, and a
main-session Bash snippet has no clean handle to its own live, mid-write session transcript. So the
load-bearing path is transcript-LESS, and it does not need one: the BOARD is ground truth for
"covered" — a ticket the drain validly closed out has LEFT the open inbox (moved to Done/Blocked), so
the still-open `Recirculation ∧ Todo` set IS exactly the un-disposed set. The transcript-derived
branch/PR/valid-closeout enrichment is dropped here (it is a nice-to-have that is simply unavailable
in this shape); the checkpoint records what the board makes available (dispositions-so-far) plus the
load-bearing resume instruction. Both invocation points (autorun-pass-top, end-of-recirculate) are
therefore symmetric and transcript-less — the correct, always-available, kill-safe core.

REUSE (Stage C's logic is already factored into callable functions — import, don't re-implement).
From `scripts/hooks/idc_recirc_closeout_gate.py`: `_read_backend`, `_fs_still_open_and_handled`,
`_gh_still_open_and_handled_and_commenter`, `_checkpoint_body`, `_fs_comment`. From
`scripts/hooks/idc_ledger.py`: `read_taints` / `set_taint` / `clear_taint`, `CHECKPOINT_TAINT`.

FAIL MODE (P4). This is an ACTION script inside the drain LOOP, not a pre-action gate: it FAILS SOFT
(observe) and NEVER crashes the loop — a top-level guard warns + exits 0 on any internal error, and
argument/usage errors exit 2. It is REPO-GATED (an instant no-op outside an IDC-governed repo) and
honors `IDC_HOOKS_OBSERVE_ONLY=1` as a PURE DRY RUN — it warns what it WOULD checkpoint/clear and
mutates NEITHER the board NOR the ledger (crucially it does NOT pre-write the taint, which would latch
the ticket and rob a later enforce pass of its resume comment).

GITHUB is best-effort (not hermetically tested), and the reconciliation reads the board itself
(one `fetch_items` per pass) — a cheap read inside the DRAIN LOOP, NOT on the stop path (the Stop
gate stays 0-GraphQL; that guarantee is unaffected). The backend is auto-detected from the governed
repo's config (like the Stage C gate), so a github repo needs no `--backend` flag.

Invocation (mirrors idc_autorun_drain.py's shell-out to idc_acceptance_check.py):
    python3 idc_recirc_reconcile.py --repo <cwd> [--backend filesystem|github]
        [--tracker <TRACKER.md>] [--session-id <sid>]
Output (stable, greppable — the drain loop reads the verdict line, never the exit code):
    recirc_inbox: <n|unknown>
    reconcile: <reconciled|complete|unknown|ungoverned>
    checkpointed: <space-separated ticket #s>
    cleared: <space-separated ticket #s>
Exit 0 = ran (reconciled / no-op / unknown — all fail-soft); 2 = usage error.
"""
import argparse
import os
import sys

# Stage C's gate + the ledger live in scripts/hooks/ — put that dir on sys.path so we IMPORT the
# already-factored functions rather than re-implementing them (this script lives in scripts/).
_HOOKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks")
sys.path.insert(0, _HOOKS)
import idc_hook_lib as H          # noqa: E402  (is_governed_repo / observe_only / warn)
import idc_ledger                 # noqa: E402  (the taint API — import, never edit)
import idc_recirc_closeout_gate as G  # noqa: E402  (reuse the factored reconciliation helpers)

CHECKPOINT_TAINT = G.CHECKPOINT_TAINT   # "recirc_checkpoint" (defined in the Stage C gate)


def _plugin_root():
    """The plugin root — the parent of scripts/ (this file is scripts/idc_recirc_reconcile.py). Used
    to locate the sibling tracker/closeout helpers the reused functions shell out to."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _existing_checkpoint_keys(cwd):
    """Every ticket number that currently carries a `recirc_checkpoint` taint, read UNSCOPED
    (`read_taints`, not `pending_taints(session)`): kill-recovery spans sessions — a taint a DEAD
    prior drain left behind is exactly what this pass must reconcile, so the current session's id must
    not filter it out. A non-numeric key is ignored (can't be matched to a board ticket number)."""
    keys = set()
    for t in idc_ledger.read_taints(cwd):
        if t.get("kind") != CHECKPOINT_TAINT:
            continue
        try:
            keys.add(int(t.get("key")))
        except (TypeError, ValueError):
            continue
    return keys


def reconcile(cwd, backend, session_id):
    """The deterministic reconciliation. Returns (verdict, checkpointed, cleared, inbox_n) where
    inbox_n is None on an unreadable inbox."""
    plugin_root = _plugin_root()

    # Repo-gate: an instant no-op outside a governed repo (the ledger writes would no-op anyway, but
    # short-circuit so a stray call never even reads the board).
    if not H.is_governed_repo(cwd):
        return "ungoverned", [], [], None

    # Which inbox tickets are still open (board = ground truth) + what was already handled (Done/
    # Blocked — enriches the checkpoint's dispositions-so-far). Reuses Stage C's readers verbatim.
    if backend == "github":
        still_open, handled, commenter = G._gh_still_open_and_handled_and_commenter(cwd, plugin_root)
    else:
        still_open, handled = G._fs_still_open_and_handled(plugin_root, cwd)
        trk = os.path.join(plugin_root or "", "scripts", G.TRACKER_FS)
        tracker = os.path.join(cwd, "TRACKER.md")
        commenter = lambda n, body: G._fs_comment(trk, tracker, cwd, n, body)  # noqa: E731

    if still_open is None:
        # UNKNOWN inbox — the tracker/board could not be read. We CANNOT prove the inbox is empty, so
        # we must NOT clear any taint (clearing on an unproven-empty inbox is the exact drop-F state
        # loss / MAJOR-1) and must NOT stamp (we don't know which tickets). Preserve everything, warn.
        H.warn("recirc-reconcile: could not determine the recirculation inbox (tracker/board "
               "unreadable) — preserving existing checkpoint taints, stamping nothing (state NOT wiped)")
        return "unknown", [], [], None

    still_set = set(still_open)
    existing = _existing_checkpoint_keys(cwd)   # the idempotence latch + the clear candidates
    observe = H.observe_only()

    clear_candidates = sorted(k for k in existing if k not in still_set)
    # The taint is the idempotence latch: an open ticket already in `existing` was checkpointed on a
    # prior pass → skip (no duplicate comment).
    to_checkpoint = [t for t in still_open if t not in existing]

    if observe:
        # OBSERVE-ONLY is a pure dry run: NO ledger mutation and NO board comment, only a report of
        # what WOULD happen. Critically it must NOT write the taint either — otherwise a later
        # enforce pass would find the ticket already-latched and NEVER write its resume comment (the
        # breadcrumb the whole gate exists to leave). So observe engages neither the clear nor the
        # set — it leaves the ledger exactly as it found it.
        if clear_candidates:
            H.warn(f"OBSERVE-ONLY: would clear stale checkpoint taints {clear_candidates} "
                   "(their tickets left the inbox) — ledger untouched")
        if to_checkpoint:
            H.warn(f"OBSERVE-ONLY: would checkpoint open un-checkpointed tickets {to_checkpoint} "
                   "(resume comment + taint) — board + ledger untouched")
        return ("complete" if not still_open else "reconciled"), [], [], len(still_open)

    # CLEAR — a checkpoint taint whose ticket has LEFT the open inbox (absorbed/Done/Blocked). The
    # obligation is satisfied; the breadcrumb is stale. Ticket-keyed + cross-session on purpose.
    for k in clear_candidates:
        idc_ledger.clear_taint(cwd, CHECKPOINT_TAINT, key=k)

    # CHECKPOINT — every open ticket WITHOUT a taint yet, transcript-LESS (main-session origin — the
    # body must NOT claim a subagent/transcript, which would be false recovery evidence).
    checkpointed = []
    for t in to_checkpoint:
        commenter(t, G._checkpoint_body(t, None, [], handled, origin="main-session"))
        # The taint is written by this script (never the LLM), keyed by ticket, attributed to this
        # drain session; it clears above once the ticket leaves the inbox. `via` marks its origin.
        idc_ledger.set_taint(cwd, CHECKPOINT_TAINT, key=t, session_id=session_id,
                             branch="", prs="", via="main-session-reconcile")
        checkpointed.append(t)

    verdict = "complete" if not still_open else "reconciled"
    return verdict, checkpointed, clear_candidates, len(still_open)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Main-session recirculation closeout-or-checkpoint reconciliation (v4 Phase 3 E1)")
    ap.add_argument("--repo", default=".", help="governed workspace root (default: cwd)")
    ap.add_argument("--backend", choices=("filesystem", "github"), default=None,
                    help="tracker backend (default: auto-detect from docs/workflow/tracker-config.yaml, "
                         "else filesystem) — mirrors the Stage C gate; a github repo needs no flag")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem); its dir is used as the repo root")
    ap.add_argument("--session-id", dest="session_id", default=None,
                    help="session id for taint attribution (default: $CLAUDE_CODE_SESSION_ID)")
    args = ap.parse_args(argv)

    # The filesystem readers key off <cwd>/TRACKER.md, so a --tracker anchors the repo root at its dir.
    if args.tracker:
        cwd = os.path.dirname(os.path.abspath(args.tracker)) or "."
    else:
        cwd = os.path.abspath(args.repo)
    sid = args.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID") or None
    # Auto-detect the backend from the governed repo's config when not forced, exactly like the Stage C
    # gate's _read_backend — so a github repo whose caller forgot --backend github is NOT silently read
    # as an absent filesystem tracker (a permanent, protection-off `reconcile: unknown` every pass).
    backend = args.backend or (G._read_backend(cwd) or "filesystem")

    verdict, checkpointed, cleared, inbox_n = reconcile(cwd, backend, sid)
    print("recirc_inbox: " + ("unknown" if inbox_n is None else str(inbox_n)))
    print("reconcile: " + verdict)
    print("checkpointed: " + " ".join(str(t) for t in checkpointed))
    print("cleared: " + " ".join(str(t) for t in cleared))
    return 0


if __name__ == "__main__":
    # FAIL-SOFT top-level guard: a reconcile error must NEVER crash the drain loop (this is an action
    # step, not a pre-action gate). Warn + exit 0 on any internal error; argparse usage errors exit 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as _e:  # noqa: BLE001 — infra bug, never a reason to break the drain loop
        H.warn(f"recirc-reconcile errored, failing soft (drain loop continues): {_e}")
        sys.exit(0)
