#!/usr/bin/env python3
"""idc_finish_recover.py — complete a finish that a DEAD session started and never finished.

WHY THIS EXISTS. `idc_git_finish.py`'s tail merges the PR — which is also what closes the linked
issue, via the mandated `Closes #N` — and flips the board several steps later, in the same process.
A session that dies in that window (a kill, context exhaustion, a mid-way handoff to a fresh session)
leaves the item **merged, its issue closed, and the board still `In Progress`** — permanently, with
nothing to say the close was ever underway. Seven items in one governed repo ended a session in
exactly that state (`docs/dev/2026-07-19-completion-honesty.md`).

The finish tail now RECORDS that window: it sets the ledger's own `mid_finish:<item>` obligation
before the merge and clears it only after the board flip is verified. This script is the other half —
the part that lets a **different, later session finish what it did not start**.

CROSS-SESSION BY CONSTRUCTION — and that is the whole point. The taint we must act on belongs, by
definition, to a session that is already dead, so this reads the **UNSCOPED** ledger
(`idc_ledger.read_taints`, never `pending_taints(session_id=…)`). Scoping to the running session
would hide precisely the obligation this exists to discharge. `idc_recirc_reconcile.py` already
established this shape for the same reason ("kill-recovery spans sessions"); the ledger's own
docstring sanctions the unscoped read "for cross-session recovery/inspection".

THE BOARD IS GROUND TRUTH; THE LEDGER IS A HINT (`idc_ledger.py` INVARIANT #1, which this must not
break). So every taint is answered by asking the BOARD first:
  * ALREADY TERMINAL (the item is Done, and on github its issue CLOSED) → the obligation is
    discharged; CLEAR the taint and touch nothing else. This is the stale-ledger case — a session
    that died after the flip but before the clear — and it must resolve cleanly rather than wedge
    the pipe. Clearing here (instead of re-running a close that would succeed anyway) is also what
    keeps a SECOND recovery pass honest: the repo's terminal transition has no already-terminal
    guard, so a re-close appends a SECOND journal record for one real close.
  * NOT TERMINAL → complete it through the EXISTING idempotent door, `idc_git_finish.py
    --close-only`, which verifies the PR really is MERGED (its receipt), proves the merged PR owns
    the item, refuses to delete an advanced branch, closes both halves of the tracker and reads the
    end state back. No second write path is minted here; this script only decides WHICH taints to
    hand to that door.
  * UNREADABLE (board/tracker unknown) → never guessed in either direction: fall through to the
    door, which is itself fail-closed, and report whatever it concludes.

A TAINT THAT CANNOT BE DISCHARGED IS NEVER SILENTLY DROPPED. If the door refuses (the PR is not
merged — the finish died BEFORE the merge, so nothing shipped — or the board is unreadable, or the
taint carries no PR to aim at), the taint SURVIVES and the item is named on the `unresolved:` line
with the door's own reason. Dropping it would be the state loss this exists to prevent.

RELATIONSHIP TO THE COHERENCE GATE. `idc_finish_coherence.py` DETECTS the same corruption after the
fact, from git+board evidence, and fails the wave close. The two agree by construction rather than
competing: this runs at the top of the drain pass, so a recoverable item is repaired BEFORE the gate
looks, leaving it clean; an item this cannot repair is one where nothing shipped, which the gate does
not flag either. Neither double-records — this module mutates only the ledger and delegates every
board write to the finisher, which journals exactly once.

FAIL MODE. This is an ACTION script inside the drain LOOP, not a pre-action gate, so it FAILS SOFT
and NEVER halts the drain (mirroring `idc_recirc_reconcile.py`): a top-level guard warns and exits 0
on any internal error; usage errors exit 2. It is REPO-GATED (an instant no-op outside a governed
repo) and honors `IDC_HOOKS_OBSERVE_ONLY=1` as a PURE DRY RUN — it reports what it WOULD do and
mutates neither the board nor the ledger.

Invocation (mirrors idc_recirc_reconcile.py):
    python3 idc_finish_recover.py --repo <cwd> [--session-id <sid>] [--timeout <s>]
Output (stable, greppable — read the verdict line, not the exit code):
    mid_finish: <n>
    recover: <complete|recovered|unresolved|ungoverned>
    recovered: <space-separated item #s completed through --close-only>
    cleared:   <space-separated item #s whose work was already complete (stale taint)>
    unresolved: <space-separated item #s whose taint was PRESERVED — still owed>
Exit 0 = ran (nothing to do / recovered / unresolved — all fail-soft); 2 = usage error.
"""
import argparse
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# The ledger + hook lib live in scripts/hooks/; the finisher lives beside this file. Import both
# rather than re-implementing either — the taint API, the backend/config parsers and the single-issue
# board read all already exist and must not fork.
sys.path.insert(0, os.path.join(SCRIPT_DIR, "hooks"))
sys.path.insert(0, SCRIPT_DIR)   # scripts/ first, so hooks/ can never shadow a sibling helper
import idc_hook_lib as H       # noqa: E402  (is_governed_repo / observe_only / warn)
import idc_ledger              # noqa: E402  (the taint API — import, never edit)
import idc_git_finish as GF    # noqa: E402  (MID_FINISH_TAINT + read_backend/read_config/board read)

MID_FINISH_TAINT = GF.MID_FINISH_TAINT   # "mid_finish" — defined once, in the finisher
FINISHER = os.path.join(SCRIPT_DIR, "idc_git_finish.py")
TRACKER_FS = os.path.join(SCRIPT_DIR, "idc_tracker_fs.py")
DEFAULT_TIMEOUT = 300


def _int_or_none(value):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def mid_finish_taints(cwd):
    """Every `mid_finish` obligation in the ledger, newest-key-order, read UNSCOPED.

    `read_taints` — NOT `pending_taints(session_id=…)`. See the header: the session that left this
    taint is dead, so session scoping would filter out the only records worth acting on. A taint whose
    key is not an item number cannot be matched to a board item, so it is ignored (never guessed at).
    """
    out = []
    for t in idc_ledger.read_taints(cwd):
        if t.get("kind") != MID_FINISH_TAINT:
            continue
        num = _int_or_none(t.get("key"))
        if num is None:
            continue
        fields = t.get("fields") if isinstance(t.get("fields"), dict) else {}
        out.append({
            "issue": num,
            "pr": _int_or_none(fields.get("pr")),
            "tracker": str(fields.get("tracker") or ""),
            "branch": str(fields.get("branch") or ""),
            "session_id": t.get("session_id"),
        })
    return sorted(out, key=lambda r: r["issue"])


# ── ground truth: is this item ALREADY in the state a completed finish leaves? ───────────────────
def _fs_terminal(tracker_path, issue):
    """filesystem backend — the tracker's own reader, shelled out exactly as the finisher does."""
    try:
        r = subprocess.run([sys.executable, TRACKER_FS, "--tracker", tracker_path,
                            "show", "--num", str(issue), "--field", "Status"],
                           capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None            # unreadable / no such item — unknown, never "not done"
    return r.stdout.strip() == "Done"


def _github_terminal(repo, issue, project_number, owner, name):
    """github backend — the finisher's OWN single-issue read (`gh_issue_project_status`: one GraphQL
    call via the issue's `projectItems`, never a whole-board read).

    That helper is fail-CLOSED by convention: it reports and calls `sys.exit` when the read fails.
    This script is fail-SOFT, so the SystemExit is caught and turned into "unknown" — the read
    failure is still printed by the helper itself, and an unknown answer never clears a taint."""
    pn = _int_or_none(project_number)
    if pn is None or not owner or not name:
        return None
    try:
        state, status, _item_id = GF.gh_issue_project_status(repo, owner, name, issue, pn,
                                                             "recover-precheck")
    except SystemExit:
        return None
    return state == "CLOSED" and status == "Done"


def item_terminal(repo, backend, issue, tracker_path, project_number, owner, name):
    """True (already Done) / False (still owed) / None (could not be read). Asked BEFORE any repair,
    because the board is ground truth and the ledger is only a hint."""
    if backend == "filesystem":
        return _fs_terminal(tracker_path or os.path.join(repo, "TRACKER.md"), issue)
    return _github_terminal(repo, issue, project_number, owner, name)


def close_only(repo, rec, timeout):
    """Complete one item through the EXISTING idempotent door. Returns (ok, detail).

    Shelled out rather than imported on purpose: `idc_git_finish.py` is fail-closed by `sys.exit`, and
    a subprocess boundary turns its refusals into a returncode this fail-soft loop can report instead
    of dying on. Its own verification — merged-PR receipt, ownership, containment, board read-back —
    is the authority on whether the item is really finished; nothing here second-guesses it."""
    cmd = [sys.executable, FINISHER, "--close-only",
           "--pr", str(rec["pr"]), "--issue", str(rec["issue"]), "--repo", repo]
    if rec["tracker"]:
        cmd += ["--tracker", rec["tracker"]]
    try:
        r = subprocess.run(cmd, cwd=repo, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return False, f"--close-only timed out after {timeout}s"
    except (OSError, subprocess.SubprocessError) as e:
        return False, f"--close-only could not be run ({e})"
    if r.returncode == 0:
        return True, (r.stdout or "").strip()[:200]
    detail = (r.stderr or r.stdout or "").strip().splitlines()
    return False, (detail[-1][:300] if detail else f"exit {r.returncode}")


def recover(repo, session_id, timeout):
    """The deterministic recovery. Returns (verdict, recovered, cleared, unresolved, n_taints)."""
    if not H.is_governed_repo(repo):
        return "ungoverned", [], [], [], 0

    taints = mid_finish_taints(repo)
    if not taints:
        return "complete", [], [], [], 0

    backend = GF.read_backend(repo) or "filesystem"
    project_number, _field_ids = GF.read_config(repo) if backend == "github" else ("", {})
    owner = name = None
    if backend == "github":
        try:
            owner, name = GF.gh_owner_name(repo)   # fail-closed by sys.exit → unknown, see below
        except SystemExit:
            owner = name = None

    observe = H.observe_only()
    recovered, cleared, unresolved = [], [], []

    for rec in taints:
        issue = rec["issue"]
        terminal = item_terminal(repo, backend, issue, rec["tracker"], project_number, owner, name)
        if terminal is True:
            # STALE TAINT — the work is done and the board says so. Clear it; do NOT re-run a close
            # (that would append a second journal record for one real close, and the board is the
            # authority here, not the ledger).
            if observe:
                H.warn(f"OBSERVE-ONLY: would clear the stale mid_finish taint for #{issue} "
                       "(its board item is already Done) — ledger untouched")
            else:
                idc_ledger.clear_taint(repo, MID_FINISH_TAINT, key=issue)
            cleared.append(issue)
            continue
        if rec["pr"] is None:
            # No PR to aim the door at (a hand-set or truncated taint). PRESERVE it and say so —
            # guessing a PR number could close the wrong item.
            unresolved.append(issue)
            H.warn(f"finish-recover: the mid_finish taint for #{issue} carries no PR number, so the "
                   "--close-only door cannot be aimed — preserving the obligation; recover by hand "
                   f"with: idc_git_finish.py --close-only --pr <N> --issue {issue} --repo {repo}")
            continue
        if observe:
            H.warn(f"OBSERVE-ONLY: would complete #{issue} through idc_git_finish.py --close-only "
                   f"--pr {rec['pr']} — board + ledger untouched")
            recovered.append(issue)
            continue
        ok, detail = close_only(repo, rec, timeout)
        if ok:
            # The finisher clears the taint itself on success (its own completion point); clearing
            # again is a documented no-op and keeps this correct even if that ever changes.
            idc_ledger.clear_taint(repo, MID_FINISH_TAINT, key=issue)
            recovered.append(issue)
        else:
            unresolved.append(issue)
            H.warn(f"finish-recover: #{issue} could not be completed — the obligation is PRESERVED "
                   f"(it is still owed). The door refused: {detail}")

    verdict = "unresolved" if unresolved else "recovered"
    return verdict, recovered, cleared, unresolved, len(taints)


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Complete a finish that a dead session started: discharge every cross-session "
                    "`mid_finish` obligation through the existing idempotent --close-only door.")
    ap.add_argument("--repo", default=".", help="governed workspace root (default: cwd)")
    ap.add_argument("--session-id", dest="session_id", default=None,
                    help="the RUNNING session's id (reporting only — recovery is deliberately "
                         "cross-session, so it never filters the ledger by session)")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                    help=f"seconds to allow each --close-only run (default: {DEFAULT_TIMEOUT})")
    args = ap.parse_args(argv)

    repo = os.path.abspath(args.repo)
    sid = args.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID") or None
    verdict, recovered, cleared, unresolved, n = recover(repo, sid, args.timeout)

    print(f"mid_finish: {n}")
    print("recover: " + verdict)
    print("recovered: " + " ".join(str(i) for i in recovered))
    print("cleared: " + " ".join(str(i) for i in cleared))
    print("unresolved: " + " ".join(str(i) for i in unresolved))
    return 0


if __name__ == "__main__":
    # FAIL-SOFT top-level guard: a recovery error must NEVER crash the drain loop (this is an action
    # step, not a pre-action gate). Warn + exit 0 on any internal error; argparse usage errors exit 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as _e:  # noqa: BLE001 — infra bug, never a reason to break the drain loop
        H.warn(f"finish-recover errored, failing soft (drain loop continues): {_e}")
        sys.exit(0)
