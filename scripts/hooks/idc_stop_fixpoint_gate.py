#!/usr/bin/env python3
"""idc_stop_fixpoint_gate.py — the Stop fixpoint gate (v4 Phase 3, drop E, plan §3.4).

Fired on `Stop` (the MAIN session's stop). It closes forensic drop E — an autorun/build orchestrator
session that **exits with a non-empty inbox and lies about being done**. The truth of "done" is the
whole-pipe fixpoint the drain already computes; this gate refuses the stop while the pipe is provably
NOT drained, bounded N=3 then a loud-fail with a one-time board annotation (never an infinite nag).

WHO IS GATED (self-gate — the key design decision). The Stop payload has NO `agent_type` for the main
session (only SubagentStop carries one — the Phase-1 spike), so an arbitrary claude session doing
unrelated work in a governed repo cannot be told apart from an autorun/build drain by the payload
alone. The orchestrator therefore leaves a **session-scoped marker** in the obligations ledger at
drain start: an `orchestrator_drain` taint carrying the session id (commands/autorun.md sets it via
`idc_ledger set --kind orchestrator_drain --session "$CLAUDE_CODE_SESSION_ID"`). Two facts make this
robust and were verified on Claude Code 2.1.201 before this gate was written:
  * the Stop payload's `session_id` EQUALS the `$CLAUDE_CODE_SESSION_ID` env var the orchestrator's
    own shell sees, so the marker the command writes is exactly the one this hook looks up; and
  * `idc_ledger.pending_taints(cwd, session_id=X)` is session-scoped (invariant #1 defense 1): it
    returns X's taints plus unattributed ones, NOT a *different* dead session's leftover marker — so a
    crashed drain's stale marker can never gate a later, unrelated session's stop.
No marker for THIS session ⇒ fast `exit 0` (allow) — the hot path for every non-orchestrator stop.

THE CRUX — the ledger is a HINT, the board is GROUND TRUTH (invariant #1 defense 2). The block fires
ONLY when BOTH the board (`idc_autorun_drain.py`) AND the ledger (scoped to this session) say work
remains. A clean `drain: complete` makes the board conjunct false, so **the ledger alone NEVER blocks
a clean board** — a stale, un-cleared `mid_finish`/`unfiled_findings` taint cannot hold the stop
hostage once the pipe is actually drained.

WHAT "the board says pending" MEANS. We read the SANCTIONED drain predicate `idc_autorun_drain.py`
and key on its EXISTING exit-code contract (Phase 0, unchanged here): exit 4 == `drain: recirc-pending`
— the build lane is drained (nothing eligible) but the Recirculation/Consideration inbox is non-empty,
i.e. the orchestrator's own next action is `/idc:recirculate` / plan, NOT stop. That, and only that, is
the drop-E signal. Every OTHER drain state is allowed to stop:
  * `drain: complete` (exit 0) — genuinely done (the crux ALLOW).
  * `drain: continue` (exit 0) — eligible build work remains, but that is precisely what the outer
    `/loop` iterates on turn-by-turn; blocking here would fight the /loop model (an orchestrator turn
    LEGITIMATELY yields with build work still eligible). So: allow.
  * `drain: unknown` (exit 2) / `rate-limited` (exit 3) — resumable pauses by design; /loop re-checks.
    Blocking would nag during a transient board-read failure or a quota outage. So: allow.
The gate blocks on PROVEN pending, not on inability-to-prove; the latter is a resumable-pause allow.

NO NEW BOARD GraphQL ON THE STOP PATH (the constraint). For the FILESYSTEM backend the drain is a pure
local read (zero GraphQL) — the common lightweight case and what the governance lane exercises — so the
gate re-runs it live. For the GITHUB backend a live drain is a board read; to honor the constraint the
gate does NOT scan the board on the stop path — it defers (warn + allow), leaving github stop-gating to
the /loop re-check + autorun's own prose contract (a persisted-verdict read is the clean future path;
see the telegram). The block is therefore delivered where it is free and correct (filesystem) and never
doubles the GraphQL cost of a github drain.

FAIL MODES (P4). This is a PRE-ACTION honesty gate. Once a session is CONFIRMED an orchestrator drain,
a gate-internal failure to determine drain state (the drain helper cannot be spawned) fails CLOSED — a
bounded block with a clear message — rather than let a possibly-dishonest exit through; the N=3 bound
+ Claude Code's own `stop_hook_active` backstop guarantee it can never loop forever. BEFORE the
self-gate is resolved (we don't yet know if it's an orchestrator session), an unexpected error fails
OPEN via idc_hook_lib.guard_pre_action — we must never block a session we could not even classify.
`IDC_HOOKS_OBSERVE_ONLY=1` downgrades the block to a stderr warning (allow). Repo-gated: an instant
no-op outside an IDC-governed repo.

Invocation: idc_stop_fixpoint_gate.py <PLUGIN_ROOT>   (Stop payload on stdin).
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_hook_lib as H  # noqa: E402
import idc_ledger  # noqa: E402  (import, never edit — Stage A)

# The self-gate marker the orchestrator (commands/autorun.md) sets at drain start. It is BOTH the
# "who to gate" signal AND the ledger's minimal obligation for a live drain ("this session owes a
# completed drain"); mid_finish/unfiled_findings/recirc_checkpoint enrich the obligation set.
ORCHESTRATOR_MARKER = "orchestrator_drain"
DRAIN = "idc_autorun_drain.py"
ACCEPT = "idc_acceptance_check.py"  # referenced only in prose here; the drain loop invokes it (--acceptance)
_RECIRC_PENDING_EXIT = 4  # idc_autorun_drain.py's `drain: recirc-pending` exit code (Phase 0 contract)


def _read_backend(cwd):
    """The `backend:` value from <cwd>/docs/workflow/tracker-config.yaml (grep/regex parse, the repo's
    no-yq convention — so the stop path never needs PyYAML), or None if absent/unreadable."""
    cfg = os.path.join(cwd, "docs", "workflow", "tracker-config.yaml")
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*backend:\s*([A-Za-z0-9_-]+)", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        return None
    return None


def _drain_detail(stdout):
    """A compact human string of the drain's two always-on counts + its verdict, for the block reason."""
    parts = []
    v = re.search(r"^drain:\s*(.+)$", stdout, re.M)
    if v:
        parts.append(f"drain: {v.group(1).strip()}")
    ri = re.search(r"^recirc_inbox:\s*(\d+)", stdout, re.M)
    if ri:
        parts.append(f"recirc_inbox={ri.group(1)}")
    uc = re.search(r"^unplanned_considerations:\s*(\d+)", stdout, re.M)
    if uc:
        parts.append(f"unplanned_considerations={uc.group(1)}")
    return ", ".join(parts) or "the pipe is not at a whole-pipe fixpoint"


def _board_says_pending(cwd, plugin_root):
    """(board_pending, detail).

    board_pending is True ONLY when the drain PROVES a non-empty inbox with the build lane drained
    (`idc_autorun_drain.py` exit 4 / `drain: recirc-pending`). complete/continue/unknown/rate-limited
    → False (clean, or a resumable pause — never fight /loop or a rate-limit pause). GITHUB → False +
    warn (no board GraphQL on the stop path — the constraint). RAISES on a gate-internal failure (the
    drain helper is missing / cannot be spawned / times out) so the caller fails CLOSED."""
    backend = _read_backend(cwd)
    if backend == "github":
        H.warn("stop-fixpoint: github backend — deferring to the /loop re-check "
               "(no board GraphQL on the stop path)")
        return False, "github (deferred)"
    tracker = os.path.join(cwd, "TRACKER.md")
    if not os.path.isfile(tracker):
        # A governed filesystem repo with no TRACKER.md is a transient/misconfig state, not a proven
        # non-empty inbox: allow (don't nag on infra absence) rather than fail closed.
        H.warn(f"stop-fixpoint: no TRACKER.md under {cwd} — cannot determine drain state; allowing")
        return False, "no tracker"
    drain = os.path.join(plugin_root or "", "scripts", DRAIN)
    if not os.path.isfile(drain):
        raise RuntimeError(f"drain helper not found at {drain}")
    r = subprocess.run([sys.executable, drain, "--tracker", tracker],
                       cwd=cwd, capture_output=True, text=True, timeout=30)
    return (r.returncode == _RECIRC_PENDING_EXIT), _drain_detail(r.stdout)


def _obligation_labels(pending_taints):
    """The session's ledger obligations OTHER than the bare orchestrator marker (mid_finish:<item>,
    unfiled_findings, recirc_checkpoint:<ticket>), as `kind` or `kind:key` labels — for the reason."""
    out = set()
    for t in pending_taints:
        if t.get("kind") == ORCHESTRATOR_MARKER:
            continue
        k = t.get("kind")
        out.add(f"{k}:{t['key']}" if t.get("key") is not None else str(k))
    return sorted(out)


def _block_reason(detail, pending_taints):
    obligations = _obligation_labels(pending_taints)
    owed = (f" This session also holds unfinished ledger obligations: {', '.join(obligations)}."
            if obligations else "")
    return (
        "IDC stop-fixpoint gate: this autorun/build drain session is stopping while the pipe is NOT "
        f"drained ({detail}). The build lane is empty but the Recirculation/Consideration inbox still "
        f"owes upstream work, so the run is NOT complete.{owed} Before you stop: drain the inbox with "
        "`/idc:recirculate` (and plan any admitted considerations), then re-check "
        "`${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py` — a clean `drain: complete` is the only "
        "honest stop."
    )


def _annotate_forced_exit_once(cwd, plugin_root, sid, detail):
    """At the anti-nag bound, record the forced exit ONCE on the board (drop-E is a governance miss —
    make it operator-visible, P8). A single deterministic write via the sanctioned filesystem tracker
    helper (never a raw gh/GraphQL call), guarded one-time PER SESSION so it is written at the bound,
    not per stop. Best-effort: a failed annotation must not itself break the (already loud-failing)
    allow. Filesystem only — the github stop path defers before it can reach here (no board GraphQL)."""
    annot_key = f"stop-fixpoint-annotated.{sid}"
    if H.counter_get(annot_key) >= 1:
        return
    trk = os.path.join(plugin_root or "", "scripts", "idc_tracker_fs.py")
    tracker = os.path.join(cwd, "TRACKER.md")
    if not (os.path.isfile(trk) and os.path.isfile(tracker)):
        return
    num = _first_inbox_item(trk, tracker)
    if num is None:
        return
    body = (f"[idc-stop-gate] forced exit: an autorun/build drain session stopped with a non-empty "
            f"inbox after {H.DEFAULT_BOUND} reminders ({detail}). The pipe is NOT at a whole-pipe "
            f"fixpoint — run /idc:recirculate and plan admitted considerations, then re-drain.")
    try:
        subprocess.run([sys.executable, trk, "--tracker", tracker, "comment",
                        "--num", str(num), "--body", body],
                       cwd=cwd, capture_output=True, text=True, timeout=30)
        H.counter_set(annot_key, 1)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"stop-fixpoint: could not write the forced-exit board annotation: {e}")


def _first_inbox_item(trk, tracker):
    """The lowest-numbered blocking inbox item (a Recirculation ∧ Todo ticket, else a Consideration ∧
    Todo pointer) — the item whose presence made the drain report `recirc-pending`. None if none found."""
    for stage in ("Recirculation", "Consideration"):
        try:
            r = subprocess.run([sys.executable, trk, "--tracker", tracker, "query",
                                "--stage", stage, "--status", "Todo"],
                               capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.SubprocessError):
            return None
        nums = [int(x) for x in r.stdout.split() if x.strip().isdigit()]
        if nums:
            return min(nums)
    return None


def _gate(payload, plugin_root):
    cwd = payload.get("cwd") or os.getcwd()
    sid = payload.get("session_id")

    # Repo-gate: an instant no-op outside an IDC-governed repo (the hook fires for every session).
    if not H.is_governed_repo(cwd):
        H.allow()

    # Self-gate: only an autorun/build orchestrator DRAIN session is considered — identified by the
    # session-scoped `orchestrator_drain` marker the orchestrator set at drain start. A random session
    # (no marker for THIS session_id) is never blocked. `pending_taints(session_id=sid)` is scoped, so
    # a crashed drain's stale marker owned by a DIFFERENT session is not returned here.
    pending_taints = idc_ledger.pending_taints(cwd, session_id=sid)
    if not any(t.get("kind") == ORCHESTRATOR_MARKER for t in pending_taints):
        H.allow()

    # From here we KNOW this is an orchestrator drain session → fail CLOSED on an internal error.
    key = f"stop-fixpoint.{sid}"
    try:
        board_pending, detail = _board_says_pending(cwd, plugin_root)
    except Exception as e:  # noqa: BLE001 — cannot verify the pipe is drained → prefer a clear block
        H.bounded_block(
            key,
            "IDC stop-fixpoint gate: could not verify the drain state of this autorun/build session "
            f"({e}). Failing closed (an honest stop must be provable): re-run "
            "`${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py` and confirm `drain: complete`. "
            "(Bounded — this will not block indefinitely.)")
        return  # unreachable (bounded_block exits); defensive

    # THE CRUX (invariant #1 defense 2): block ONLY when the board (ground truth) AND the ledger (hint)
    # BOTH say work remains. `ledger_pending` is non-empty here (it holds at least the orchestrator
    # marker, and any mid_finish/unfiled_findings obligations). A clean `drain: complete` makes
    # `board_pending` False → the ledger alone can NEVER block. Neutering this to `if ledger_pending:`
    # (dropping the board conjunct) is exactly what the crux governance scenario proves red-when-broken.
    ledger_pending = bool(pending_taints)
    if board_pending and ledger_pending:
        reason = _block_reason(detail, pending_taints)
        if H.observe_only():
            H.warn(f"OBSERVE-ONLY (would block stop): {reason}")
            H.allow()
        # One-time board annotation AT the bound (before bounded_block loud-fails + clears the counter).
        if H.counter_get(key) >= H.DEFAULT_BOUND:
            _annotate_forced_exit_once(cwd, plugin_root, sid, detail)
        # bounded_block: block for the first N=3 stops, then loud-fail-ALLOW (never an infinite nag;
        # Claude Code's `stop_hook_active` is the second backstop). Reuses the shared counter + bound.
        H.bounded_block(key, reason)
        return  # unreachable (bounded_block exits); defensive

    # Clean board, a resumable pause, or github-deferred → allow, and reset the anti-nag counter so a
    # later genuine recirc-pending episode starts its N=3 budget fresh.
    H.counter_clear(key)
    H.allow()


if __name__ == "__main__":
    # guard_pre_action fails OPEN on an UNEXPECTED exception (before the self-gate resolves we must
    # never block a session we could not even classify). Once _gate confirms an orchestrator session,
    # its own try/except fails CLOSED on a drain-verification failure — the deliberate P4 split.
    H.guard_pre_action(_gate)
