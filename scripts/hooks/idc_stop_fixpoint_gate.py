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
a gate-internal failure to determine drain state (the drain helper cannot be spawned, times out, or
CRASHES — exits OUTSIDE its documented {0,2,3,4} exit-code contract, e.g. an uncaught traceback = exit
1) fails CLOSED — a bounded block with a clear message — rather than let a possibly-dishonest exit
through; the N=3 bound + Claude Code's own `stop_hook_active` backstop guarantee it can never loop
forever. BEFORE the self-gate is resolved (we don't yet know if it's an orchestrator session) an
unexpected error fails OPEN via idc_hook_lib.guard_pre_action — we must never block a session we could
not even classify — and, in the same spirit, a Stop payload with NO `session_id` (an unattributable
session) is allowed BEFORE the marker lookup: a session we cannot attribute is not provably an
orchestrator, and the unscoped taint set could otherwise let a DEAD session's stale marker misclassify
it. `IDC_HOOKS_OBSERVE_ONLY=1` downgrades the block to a stderr warning (allow). Repo-gated: an instant
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
# The FULL Phase-0 drain exit-code contract: 0 complete/continue · 2 unknown · 3 rate-limited · 4
# recirc-pending. Any OTHER code means the drain itself CRASHED (an uncaught traceback exits 1) — the
# verdict is untrustworthy, so a confirmed-orchestrator caller must fail CLOSED (see _board_says_pending).
_DRAIN_CONTRACT_EXITS = (0, 2, 3, _RECIRC_PENDING_EXIT)
# The anti-nag bound this gate uses — the SINGLE source of truth threaded through BOTH the
# `bounded_block` calls AND the one-time forced-exit annotation trigger, so they can never desync if the
# bound is ever customized (a hardcoded DEFAULT_BOUND at one site would silently drift from the other).
_STOP_GATE_BOUND = H.DEFAULT_BOUND


def _read_backend(cwd):
    """The `backend:` value from <cwd>/docs/workflow/tracker-config.yaml (grep/regex parse, the repo's
    no-yq convention — so the stop path never needs PyYAML), or None if absent/unreadable."""
    cfg = os.path.join(cwd, "docs", "workflow", "tracker-config.yaml")
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                # Tolerate an optional quote on the value (`backend: "github"` / `backend: 'github'`) —
                # a bare `[A-Za-z0-9_-]+` class would fail to match a quoted value and misread the
                # backend as absent (→ treated as filesystem, a wrong-backend misclassification).
                m = re.match(r"""^\s*backend:\s*["']?([A-Za-z0-9_-]+)""", line)
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
    """(board_pending, board_complete, detail).

    board_pending is True ONLY when the drain PROVES a non-empty inbox with the build lane drained
    (`idc_autorun_drain.py` exit 4 / `drain: recirc-pending`). complete/continue/unknown/rate-limited
    → False (clean, or a resumable pause — never fight /loop or a rate-limit pause). GITHUB → False +
    warn (no board GraphQL on the stop path — the constraint). RAISES on a gate-internal failure (the
    drain helper is missing / cannot be spawned / times out) OR when the drain exits OUTSIDE its
    documented {0,2,3,4} contract (a crash = exit 1 — the verdict is untrustworthy) so the caller fails
    CLOSED.

    board_complete is True ONLY when the drain PROVES a whole-pipe fixpoint (`drain: complete`, exit 0)
    — NOT `drain: continue` (build work remains), NOT a resumable pause, NOT github-deferred. It is the
    single trustworthy "obligation satisfied" signal the caller uses to clear the orchestrator marker;
    every not-proven-complete state leaves it False so the marker is never dropped prematurely."""
    backend = _read_backend(cwd)
    if backend == "github":
        H.warn("stop-fixpoint: github backend — deferring to the /loop re-check "
               "(no board GraphQL on the stop path)")
        return False, False, "github (deferred)"
    tracker = os.path.join(cwd, "TRACKER.md")
    if not os.path.isfile(tracker):
        # A governed filesystem repo with no TRACKER.md is a transient/misconfig state, not a proven
        # non-empty inbox: allow (don't nag on infra absence) rather than fail closed.
        H.warn(f"stop-fixpoint: no TRACKER.md under {cwd} — cannot determine drain state; allowing")
        return False, False, "no tracker"
    drain = os.path.join(plugin_root or "", "scripts", DRAIN)
    if not os.path.isfile(drain):
        raise RuntimeError(f"drain helper not found at {drain}")
    r = subprocess.run([sys.executable, drain, "--tracker", tracker],
                       cwd=cwd, capture_output=True, text=True, timeout=30)
    # The drain's exit code is a CONTRACT (Phase 0): 0 complete/continue · 2 unknown · 3 rate-limited
    # · 4 recirc-pending. A code OUTSIDE that set means the drain itself CRASHED (an uncaught traceback
    # exits 1) — we did NOT get a trustworthy verdict, so we cannot prove the pipe is drained. RAISE so
    # the confirmed-orchestrator caller fails CLOSED (a bounded block) rather than silently returning
    # board_pending=False and letting a possibly-dishonest exit through (the fail-OPEN bug this closes).
    if r.returncode not in _DRAIN_CONTRACT_EXITS:
        raise RuntimeError(
            f"drain exited {r.returncode} (outside the Phase-0 contract {{0,2,3,4}}); "
            f"stderr: {(r.stderr or '').strip()[:200]!r}")
    board_pending = (r.returncode == _RECIRC_PENDING_EXIT)
    # `drain: complete` (exit 0, whole-pipe fixpoint) — distinct from `drain: continue` (also exit 0,
    # but build work still eligible), which must NOT clear the marker (the orchestrator has more to do).
    board_complete = bool(re.search(r"^drain:\s*complete\b", r.stdout or "", re.M))
    return board_pending, board_complete, _drain_detail(r.stdout)


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
            f"inbox after {_STOP_GATE_BOUND} reminders ({detail}). The pipe is NOT at a whole-pipe "
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

    # Attribution gate (fail-open-before-classify): a Stop payload with NO session_id cannot be
    # attributed to THIS session. `pending_taints(cwd, session_id=None)` returns the UNSCOPED taint set
    # (the ledger's documented full-hint mode), so a stale `orchestrator_drain` marker left by a
    # DIFFERENT, dead session would otherwise misclassify this unattributable stop as an orchestrator
    # drain and false-BLOCK it. A session we cannot attribute is not provably an orchestrator, so allow —
    # BEFORE the marker lookup. (We must never block a session we could not even classify.)
    if not sid:
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
        board_pending, board_complete, detail = _board_says_pending(cwd, plugin_root)
    except Exception as e:  # noqa: BLE001 — cannot verify the pipe is drained → prefer a clear block
        H.bounded_block(
            key,
            "IDC stop-fixpoint gate: could not verify the drain state of this autorun/build session "
            f"({e}). Failing closed (an honest stop must be provable): re-run "
            "`${CLAUDE_PLUGIN_ROOT}/scripts/idc_autorun_drain.py` and confirm `drain: complete`. "
            "(Bounded — this will not block indefinitely.)",
            bound=_STOP_GATE_BOUND)
        return  # unreachable (bounded_block exits); defensive

    # THE CRUX (invariant #1 defense 2): block ONLY when the board (ground truth) AND the ledger (hint)
    # BOTH say work remains. `ledger_pending` is non-empty here (it holds at least the orchestrator
    # marker, and any mid_finish/unfiled_findings obligations). A clean `drain: complete` makes
    # `board_pending` False → the ledger alone can NEVER block. Neutering this to `if ledger_pending:`
    # (dropping the board conjunct) is exactly what the crux governance scenario proves red-when-broken.
    #
    # NOTE (m2 — do not "strengthen" this into an independent ledger check): past the self-gate above,
    # `ledger_pending` is ALWAYS True — the very marker that let us reach here guarantees ≥1 taint — so
    # the EFFECTIVE block predicate is purely `board_pending` (the drain reporting recirc-pending / exit
    # 4). This is by design: the marker is the session's MINIMAL obligation, and the board/drain is the
    # real gate. A `mid_finish` / `unfiled_findings` taint ALONE can never gate a stop — only a proven
    # non-empty inbox (the board) can. Do not assume otherwise: the ledger conjunct is a design guard
    # (it documents "block needs the board"), not a second, independent must-pass condition.
    ledger_pending = bool(pending_taints)
    if board_pending and ledger_pending:
        reason = _block_reason(detail, pending_taints)
        if H.observe_only():
            H.warn(f"OBSERVE-ONLY (would block stop): {reason}")
            H.allow()
        # One-time board annotation AT the bound (before bounded_block loud-fails + clears the counter).
        # Keyed on the SAME `_STOP_GATE_BOUND` the block below uses, so the annotate-trigger and the
        # loud-fail can never desync (a hardcoded DEFAULT_BOUND here would drift if the bound changed).
        if H.counter_get(key) >= _STOP_GATE_BOUND:
            _annotate_forced_exit_once(cwd, plugin_root, sid, detail)
        # bounded_block: block for the first N=3 stops, then loud-fail-ALLOW (never an infinite nag;
        # Claude Code's `stop_hook_active` is the second backstop). Reuses the shared counter + bound.
        H.bounded_block(key, reason, bound=_STOP_GATE_BOUND)
        return  # unreachable (bounded_block exits); defensive

    # OBLIGATION SATISFIED (m5 — clear the marker on a PROVEN-complete pipe). When this confirmed
    # orchestrator stops with `drain: complete` (a whole-pipe fixpoint), the drain obligation is met, so
    # clear the session's `orchestrator_drain` marker: a completed run then leaves NO stale marker to
    # falsely classify a LATER, unrelated stop (it complements the absent-session_id guard above — one
    # fewer piece of misclassify fuel). Guarded on `board_complete` (proven `drain: complete`, exit 0)
    # ONLY — never on `drain: continue` (build work remains — the orchestrator has more to do), never on
    # a resumable pause / unknown / github-deferred (not proven done). We clear ONLY the marker; other
    # obligations (mid_finish / unfiled_findings) are cleared by their own deterministic completion
    # points (Stage C/D), consistent with invariant #1 (a taint clears only when its action completes).
    # Best-effort by construction: clear_taint is repo-gated + tolerant and never raises on the stop path.
    if board_complete:
        idc_ledger.clear_taint(cwd, ORCHESTRATOR_MARKER)

    # Clean board, a resumable pause, or github-deferred → allow, and reset the anti-nag counter so a
    # later genuine recirc-pending episode starts its N=3 budget fresh.
    H.counter_clear(key)
    H.allow()


if __name__ == "__main__":
    # guard_pre_action fails OPEN on an UNEXPECTED exception (before the self-gate resolves we must
    # never block a session we could not even classify). Once _gate confirms an orchestrator session,
    # its own try/except fails CLOSED on a drain-verification failure — the deliberate P4 split.
    H.guard_pre_action(_gate)
