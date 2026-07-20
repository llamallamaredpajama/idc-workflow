#!/usr/bin/env python3
"""idc_pause_check.py — the ONE reader that answers "is this run at a clean stopping point?"

WHAT THIS EXISTS FOR. `/idc:pause` is a GRACEFUL stop: it finishes the item currently in flight —
including flipping its board card — and only then stops before starting anything new. The whole point
is that `/idc:resume` never has to reconstruct a partially-finished item. That promise is worth
exactly as much as the check behind it, so this module is the check: a read-only, fail-closed
re-derivation of "nothing is half-done", from durable state only.

WHY A READER AND NOT PROSE. Nothing here is a new detector. Each of the three questions below is
answered by a source that ALREADY owns it, so this reader and the rest of the pipe can never drift:

  1. Did anything SHIP while the board still advertises it as in flight?
     → `idc_finish_coherence.py` (which itself reuses the janitor's coherence verdict). This is the
       exact failure the 4.2.0 completion-honesty work closed; a pause taken over it would record a
       "clean" stop on top of a board that is lying.
  2. Does the board still CLAIM an item is being worked?
     → the shared tracker reader (`idc_next_action._load_tracker_issues`): any item at
       `Status = In Progress` is, by the board's own account, an item someone started and did not
       finish. A graceful pause must have no such item; an ungraceful one leaves exactly this.
  3. Did a deterministic multi-step action START and never COMPLETE?
     → the obligations ledger (`idc_ledger`). A `mid_finish:<item>` taint means the finish tail began
       closing an item and did not get to the end; a `recirc_checkpoint:<ticket>` taint means the
       recirculator stopped mid-drain with that ticket checkpointed. Both are the textbook half-done
       state. Read UNSCOPED (every session's taints, not just the caller's) because a pause is a
       REPO-level statement: a dead session's un-cleared mid_finish is still half-done work sitting in
       this repo, and resuming on top of it is precisely what must not happen.
     Deliberately NOT consulted: `unfiled_findings` (no shipped writer sets it, and it is about
     routing reviewer nits, not an item left half-built) and `orchestrator_drain` (that marker means a
     drain is LIVE — which is the normal state when someone pauses — not that anything is half-done).

EVERY BLOCK NAMES A CURE THAT CAN CLEAR IT (the rule earned by the stop-gate work: a gate that blocks
without a cure is a gate that gets switched off). Each finding carries a `cure:` line naming the
deterministic command that resolves it, and every one of those commands is a real shipped helper.

FAIL-CLOSED, and the distinction matters (mirrors `idc_finish_coherence.py`): "nothing is half-done"
and "I could not establish whether anything is half-done" are different answers, and only the first
may be reported as a clean pause. An unreadable board, a rate-limited board read, a coherence scan
that could not establish ground truth, or a crashed helper all yield exit 2 — never a clean exit 0.

Exit contract (the sibling-helper convention — see idc_finish_coherence.py / idc_acceptance_check.py):
  exit 0  `pause-ready: ok`                  — nothing is half-done; a pause taken now is honest.
  exit 1  `pause-ready: in-flight <refs>`    — those things are half-done. Each has a `cure:` line.
  exit 2  `pause-ready: error <why>`         — ground truth could not be established (INDETERMINATE).

The verdict WORD is `in-flight` rather than "gap": this is not a wave-close check and its finding is
not read by the drain's gap classifier. It is read by `idc_pause_state.py confirm` (which refuses to
record a pause on any nonzero exit) and by the `/idc:pause` closeout (which RE-RUNS this reader and
matches its exit, so a recorded pause can never outlive the proof that justified it).

Usage:
  idc_pause_check.py --repo <root> [--backend filesystem|github] [--tracker P] [--owner O]
                     [--project N] [--timeout S] [--json]
The backend is auto-detected from `docs/workflow/tracker-config.yaml` when not forced, exactly like
`idc_recirc_reconcile.py` — so a github repo needs no flags.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(_HERE, "hooks"))
import idc_ledger  # noqa: E402

COHERENCE = "idc_finish_coherence.py"
# `idc_finish_coherence.py`'s documented exit contract: 0 ok/not-applicable · 1 gap · 2 error. Anything
# outside it means that helper itself crashed, so its verdict cannot be trusted (fail closed).
_COHERENCE_EXITS = (0, 1, 2)
# The board Status that means "someone started this and has not finished it" (idc_tracker_fs.STATUSES).
IN_PROGRESS = "In Progress"
# The ledger taint kinds that each mean one deterministic multi-step action STARTED and never
# COMPLETED. Both have a shipped writer and a shipped clearer (see the cure map below).
HALF_DONE_TAINTS = ("mid_finish", "recirc_checkpoint")

# One cure per finding class. Every command named here is a real shipped helper, and running it is
# what makes the finding go away — so a block is always escapable by doing the honest thing.
_CURES = {
    "coherence": ("that item SHIPPED (its PR merged and closed the issue) but the board was never "
                  "flipped — repair it with the idempotent close-only finisher: "
                  "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py --close-only "
                  "--pr <PR> --issue <N> --repo <root>   (or /idc:janitor --apply-safe for the batch)"),
    "claimed": ("the board still claims this item is being worked — finish it "
                "(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py …), or, if its worker is "
                "gone, reconstruct its real state first with "
                "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_teammate_idle_synth.py --repo <root> "
                "--session-id <sid> and act on the class it reports"),
    "mid_finish": ("a finish tail started closing this item and never completed — re-run it "
                   "(python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_git_finish.py --close-only "
                   "--pr <PR> --issue <N> --repo <root>); the finisher clears the taint when it "
                   "completes, or clear it deterministically once the item is closed: "
                   "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/hooks/idc_ledger.py --cwd <root> clear "
                   "--kind mid_finish --key <N>"),
    "recirc_checkpoint": ("the recirculator stopped mid-drain with this ticket checkpointed — drain it "
                          "(/idc:recirculate #<ticket>); "
                          "python3 ${CLAUDE_PLUGIN_ROOT}/scripts/idc_recirc_reconcile.py --repo <root> "
                          "--session-id <sid> clears the taint once the ticket has left the inbox"),
}


class Indeterminate(Exception):
    """Ground truth could not be established — the caller reports exit 2, never a clean pause."""


def _repo_backend(repo: str):
    """(backend, project) from the governed repo's tracker config, via the ONE shared reader. Raises
    Indeterminate when a present config cannot be parsed — a repo whose backend is unreadable can
    never be proven quiescent (an unreadable truth is a refusal, never a filesystem fallback)."""
    try:
        import idc_next_action as NEXT  # noqa: E402 — lazy; the one constrained config reader
        return NEXT._read_tracker_config(repo)
    except Exception as exc:  # noqa: BLE001
        raise Indeterminate(f"the tracker config could not be read ({exc})") from exc


def _github_owner(repo: str) -> str:
    try:
        import idc_gh_board as GH_BOARD  # noqa: E402 — lazy
        return GH_BOARD._current_repository(repo).split("/", 1)[0]
    except Exception as exc:  # noqa: BLE001
        raise Indeterminate(f"the github owner could not be resolved ({exc})") from exc


def _resolve_board_args(args):
    """Fill in the board arguments the coherence scan needs, auto-detecting what the caller omitted."""
    backend = args.backend
    project = args.project
    if backend is None:
        backend, detected_project = _repo_backend(args.repo)
        project = project or detected_project
    if backend == "github":
        owner = args.owner or _github_owner(args.repo)
        if not project:
            raise Indeterminate("the github project number is not configured for this repo")
        return backend, {"owner": owner, "project": str(project)}
    tracker = args.tracker or os.path.join(args.repo, "TRACKER.md")
    return "filesystem", {"tracker": tracker}


def _coherence_findings(args, backend: str, board: dict):
    """Run `idc_finish_coherence.py` READ-ONLY and return its stale item numbers (possibly empty).

    Its exit code is the contract: 0 clean (including `not-applicable` on a non-git repo), 1 gap, 2
    INDETERMINATE. Anything else means it crashed. This never re-implements the detector — a second
    coherence derivation is exactly the drift the 4.2.0 work removed."""
    helper = os.path.join(_HERE, COHERENCE)
    if not os.path.isfile(helper):
        raise Indeterminate(f"{COHERENCE} not found next to this helper")
    cmd = [sys.executable, helper, "--repo", args.repo, "--timeout", str(args.timeout)]
    if backend == "github":
        cmd += ["--backend", "github", "--owner", board["owner"], "--project", board["project"]]
    else:
        cmd += ["--tracker", board["tracker"]]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout + 30)
    except subprocess.TimeoutExpired as exc:
        raise Indeterminate(f"{COHERENCE} timed out after {args.timeout + 30}s") from exc
    except (OSError, subprocess.SubprocessError) as exc:
        raise Indeterminate(f"{COHERENCE} could not be run ({exc})") from exc
    if r.returncode not in _COHERENCE_EXITS:
        raise Indeterminate(f"{COHERENCE} exited {r.returncode}, outside its documented contract "
                            f"{_COHERENCE_EXITS} — its verdict cannot be trusted")
    if r.returncode == 2:
        detail = (r.stdout or r.stderr or "").strip().splitlines()
        raise Indeterminate(f"coherence is unprovable ({detail[-1] if detail else 'no detail'})")
    if r.returncode == 0:
        return []
    m = re.search(r"^finish-coherence:\s*gap\s+(.+)$", r.stdout or "", re.M)
    if not m:
        raise Indeterminate(f"{COHERENCE} exited 1 without a parseable `gap` line")
    return [tok.lstrip("#") for tok in m.group(1).split() if tok.lstrip("#").isdigit()]


def _claimed_items(repo: str):
    """Board items at `Status = In Progress` — the board's OWN account of unfinished work. Any read
    failure (including a rate-limited github read) is INDETERMINATE, never an empty list."""
    try:
        import idc_next_action as NEXT  # noqa: E402 — the one shared, constrained tracker reader
        issues = NEXT._load_tracker_issues(repo)
    except Exception as exc:  # noqa: BLE001 — unreadable/rate-limited board ⇒ unprovable
        raise Indeterminate(f"the board could not be read to check for claimed items ({exc})") from exc
    return sorted(str(i["number"]) for i in issues if i.get("status") == IN_PROGRESS)


def _half_done_taints(repo: str):
    """Ledger taints that mean a deterministic action started and never completed, UNSCOPED (a dead
    session's un-cleared obligation is still this repo's half-done work). Tolerant by construction:
    the ledger reader treats a missing/corrupt file as empty, which is the honest reading — an absent
    ledger records no started-and-unfinished action."""
    out = []
    for t in idc_ledger.pending_taints(repo):
        kind = t.get("kind")
        if kind in HALF_DONE_TAINTS:
            key = t.get("key")
            out.append(f"{kind}:{key}" if key is not None else str(kind))
    return sorted(set(out))


def check(repo: str, backend=None, tracker=None, owner=None, project=None, timeout=180):
    """The whole quiescence question, as data. Returns `(exit_code, verdict, findings)` where
    `findings` is a list of `{"kind", "ref", "cure"}` records. Never raises for a normal outcome —
    an Indeterminate is converted to `(2, "error", [...])` with the reason in the single finding, so
    every caller (CLI, `idc_pause_state.confirm`, the closeout claim) reads the same three answers."""
    args = argparse.Namespace(repo=os.path.abspath(repo), backend=backend, tracker=tracker,
                              owner=owner, project=project, timeout=timeout)
    try:
        resolved_backend, board = _resolve_board_args(args)
        findings = []
        for num in _coherence_findings(args, resolved_backend, board):
            findings.append({"kind": "coherence", "ref": f"#{num}", "cure": _CURES["coherence"]})
        for num in _claimed_items(args.repo):
            findings.append({"kind": "claimed", "ref": f"#{num}", "cure": _CURES["claimed"]})
        for taint in _half_done_taints(args.repo):
            kind, _, key = taint.partition(":")
            findings.append({"kind": kind, "ref": f"#{key}" if key.isdigit() else (key or kind),
                             "cure": _CURES[kind]})
    except Indeterminate as exc:
        return 2, "error", [{"kind": "error", "ref": str(exc), "cure":
                             "establish ground truth first (fix the board/config read, then re-run "
                             "/idc:pause) — an unprovable state is never recorded as a clean pause"}]
    if findings:
        return 1, "in-flight", findings
    return 0, "ok", []


def report(code: int, verdict: str, findings: list, as_json: bool = False) -> None:
    """Print the machine-readable verdict line (+ one `cure:` line per finding), or `--json`."""
    if as_json:
        print(json.dumps({"verdict": verdict, "exit": code, "findings": findings}, sort_keys=True))
        return
    if verdict == "ok":
        print("pause-ready: ok")
        return
    if verdict == "error":
        print(f"pause-ready: error {findings[0]['ref'] if findings else 'unknown'}")
        return
    print("pause-ready: in-flight " + " ".join(f"{f['kind']}:{f['ref']}" for f in findings))
    for f in findings:
        print(f"cure: {f['kind']}:{f['ref']} — {f['cure']}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="idc_pause_check.py",
        description="Report whether this run is at a clean stopping point (nothing half-done). "
                    "Read-only; fail-closed.")
    ap.add_argument("--repo", default=".", help="the governed repo root (default: cwd)")
    ap.add_argument("--backend", choices=("filesystem", "github"), default=None,
                    help="tracker backend (default: auto-detect from docs/workflow/tracker-config.yaml)")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem backend)")
    ap.add_argument("--owner", help="project owner login (github backend)")
    ap.add_argument("--project", help="integer project number (github backend)")
    ap.add_argument("--timeout", type=int, default=180,
                    help="seconds to allow the coherence scan (default: 180)")
    ap.add_argument("--json", action="store_true", help="emit the verdict as one JSON object")
    args = ap.parse_args(argv)
    code, verdict, findings = check(args.repo, backend=args.backend, tracker=args.tracker,
                                    owner=args.owner, project=args.project, timeout=args.timeout)
    report(code, verdict, findings, as_json=args.json)
    return code


if __name__ == "__main__":
    # Broken-pipe guard: this CLI has a --json mode AND prints one unbounded `cure:` line per finding —
    # both halves of the criterion in scripts/idc_stdio.py, and exactly the shape an operator pipes to
    # `jq` or `head` while deciding whether a pause is safe.
    import idc_stdio
    raise SystemExit(idc_stdio.run_guarded(main))
