#!/usr/bin/env python3
"""idc_pr_finish.py — the sanctioned PR finisher (v4 command integrity, Task 3).

Plan and the Recirculator open PRs (a planning PR, a recirculation change-order PR) that must be
merged to complete a run, but that close NO tracker item — so the receipt-gated `idc_git_finish.py`
(which validates a review verdict and closes an issue) does not fit, and the agents used to type a
raw `gh pr merge --squash --delete-branch` by hand. Under the hardened mutation interlock that raw
merge is now DENIED inside an active `/idc:*` command. This helper is the sanctioned door for those
merges: it validates the PR, merges it through `gh` run as a subprocess (never the Bash tool, so the
interlock never sees a raw `gh pr merge`), and returns a JSON receipt.

Two modes:

  autonomous --repo R --pr N --kind planning|recirculation|intake
      For an autonomous merge that closes NO tracker item (a planning / recirculation / intake PR).
      Verifies the PR is OPEN, MERGEABLE, and its head branch matches the kind's prefix
      (plan/ · recirc/ · intake/), squash-merges with branch deletion, re-reads state=MERGED, and
      prints a receipt. It NEVER closes or mutates a tracker item.

  requirements --repo R --pr N --gate G --pointer P [--operator-approved]
      The requirements-admission tail: merge the bound Think/decision PR (only with explicit operator
      approval when still open) and then run the guarded dispose-before-unblock through the engine.
      Two legal paths:
        * PR already MERGED — re-verify the gate carries EXACTLY ONE idc-gate-pr body marker naming
          THIS PR, then `idc_transition.py dispose --disposition gate-approved --num G`, then
          `idc_transition.py unblock --num P --by G` (readback-verified by the engine).
        * PR OPEN — require --operator-approved (IDC never infers human approval), merge the bound PR,
          re-verify MERGED, then the SAME dispose-before-unblock tail.
      It EXITS before any tracker mutation if the PR is unmerged (no --operator-approved), markerless,
      double-marked, or bound to another PR; and if the dispose fails it does NOT unblock.

Exit: 0 = done (+ JSON receipt on stdout); 2 = a guard refused / a gh or engine failure; 3 = the
engine reported a resumable board error (github throttle). Stdlib only; `gh` via subprocess.
"""
import argparse
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TRANSITION = os.path.join(HERE, "idc_transition.py")

# kind -> the head-branch prefix an autonomous merge of that kind must carry.
KIND_PREFIX = {"planning": "plan/", "recirculation": "recirc/", "intake": "intake/"}
GATE_PR_MARKER = re.compile(r"<!--\s*idc-gate-pr:\s*(\d+)\s*-->")


class FinishError(Exception):
    """A refused finish (a failed guard, a gh failure, or a non-zero engine op). `code` is the CLI
    exit status — 2 for a guard/gh denial, or the engine's own code (2 denied / 3 resumable)."""

    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def _gh(args, repo):
    r = subprocess.run(["gh", *args], cwd=repo, capture_output=True, text=True)
    if r.returncode != 0:
        raise FinishError(f"gh {' '.join(args)} failed: {r.stderr.strip()[:200]}")
    return r.stdout


def pr_view(repo, pr, fields):
    try:
        return json.loads(_gh(["pr", "view", str(int(pr)), "--json", ",".join(fields)], repo))
    except ValueError as e:
        raise FinishError(f"could not parse PR #{pr} json ({e})")


def issue_view(repo, num, fields):
    try:
        return json.loads(_gh(["issue", "view", str(int(num)), "--json", ",".join(fields)], repo))
    except ValueError as e:
        raise FinishError(f"could not parse issue #{num} json ({e})")


def _is_merged(info):
    return info.get("state") == "MERGED" or bool(info.get("mergedAt"))


def _merge_pr(repo, pr):
    """Squash-merge + delete the branch atomically (never GitHub --auto), then confirm MERGED."""
    _gh(["pr", "merge", str(int(pr)), "--squash", "--delete-branch"], repo)
    after = pr_view(repo, pr, ["state", "mergedAt"])
    if not _is_merged(after):
        raise FinishError(f"PR #{pr} did not reach MERGED after the squash-merge (state={after.get('state')!r})")
    return after


def _transition(args, extra):
    """Run the engine (idc_transition.py) as the single write door for the dispose/unblock tail.
    Forwards --repo and any backend/owner/project/tracker the caller passed. A non-zero engine exit
    raises FinishError carrying the engine's exit code (2 denied / 3 resumable), so a refused dispose
    stops the tail BEFORE the unblock."""
    cmd = [sys.executable, TRANSITION, "--repo", args.repo]
    if args.backend:
        cmd += ["--backend", args.backend]
    if args.tracker:
        cmd += ["--tracker", args.tracker]
    if args.owner:
        cmd += ["--owner", args.owner]
    if args.project:
        cmd += ["--project", str(args.project)]
    cmd += extra
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise FinishError(f"engine op {' '.join(extra)} failed (exit {r.returncode}): "
                          f"{r.stderr.strip()[:200]}", code=r.returncode if r.returncode in (2, 3) else 2)
    return r.stdout


# ── autonomous: merge a planning/recirculation/intake PR that closes NO tracker item ──────────────
def cmd_autonomous(args):
    prefix = KIND_PREFIX[args.kind]
    info = pr_view(args.repo, args.pr, ["state", "mergeable", "headRefName"])
    if info.get("state") != "OPEN":
        raise FinishError(f"autonomous: PR #{args.pr} is {info.get('state')!r}, not OPEN — nothing to finish")
    if info.get("mergeable") != "MERGEABLE":
        raise FinishError(f"autonomous: PR #{args.pr} is not mergeable (mergeable={info.get('mergeable')!r}) "
                          "— resolve conflicts / wait for checks, then re-run")
    head = info.get("headRefName") or ""
    if not head.startswith(prefix):
        raise FinishError(f"autonomous: PR #{args.pr} head branch {head!r} does not match --kind {args.kind} "
                          f"(expected prefix {prefix!r}) — refuse to merge a mismatched PR")
    _merge_pr(args.repo, args.pr)
    receipt = {"op": "pr-finish", "mode": "autonomous", "kind": args.kind, "pr": int(args.pr),
               "head": head, "state": "MERGED", "tracker_mutation": "none"}
    print(json.dumps(receipt, sort_keys=True))
    return 0


# ── requirements: merge the bound gate PR (with approval) then dispose-before-unblock ─────────────
def _bound_pr(args):
    """The gate's own recorded approval PR: EXACTLY ONE idc-gate-pr body marker, naming THIS --pr.
    Refuses a markerless / double-marked / other-PR-bound gate BEFORE any tracker mutation."""
    info = issue_view(args.repo, args.gate, ["body"])
    prs = GATE_PR_MARKER.findall(info.get("body") or "")
    if not prs:
        raise FinishError(f"requirements: gate #{args.gate} carries no idc-gate-pr body marker (markerless) "
                          "— migrate the legacy gate by stamping the marker in its BODY, then re-run")
    if len(prs) > 1:
        raise FinishError(f"requirements: gate #{args.gate} carries {len(prs)} idc-gate-pr body markers "
                          "(double-marked) — keep exactly one (the canonical footer)")
    bound = int(prs[0])
    if bound != int(args.pr):
        raise FinishError(f"requirements: gate #{args.gate}'s bound approval PR is #{bound}, not --pr #{args.pr} "
                          "— the approval artifact must be bound to THIS gate")
    return bound


def cmd_requirements(args):
    _bound_pr(args)   # fail-closed BEFORE any tracker mutation (markerless / double / other-PR-bound)
    info = pr_view(args.repo, args.pr, ["state", "mergeable", "mergedAt"])
    if not _is_merged(info):
        # OPEN path: an explicit in-session operator approval is REQUIRED (IDC never infers it).
        if not args.operator_approved:
            raise FinishError(f"requirements: PR #{args.pr} is not merged and --operator-approved was not "
                              "given — IDC never infers human approval; leave the gate Blocked and move on")
        if info.get("state") != "OPEN":
            raise FinishError(f"requirements: PR #{args.pr} is {info.get('state')!r}, neither MERGED nor OPEN")
        if info.get("mergeable") != "MERGEABLE":
            raise FinishError(f"requirements: PR #{args.pr} is not mergeable (mergeable={info.get('mergeable')!r})")
        _merge_pr(args.repo, args.pr)
    # MERGED confirmed → the guarded dispose-before-unblock tail (dispose FIRST; if it fails, no unblock).
    _transition(args, ["dispose", "--disposition", "gate-approved", "--num", str(int(args.gate))])
    _transition(args, ["unblock", "--num", str(int(args.pointer)), "--by", str(int(args.gate))])
    receipt = {"op": "pr-finish", "mode": "requirements", "pr": int(args.pr), "gate": int(args.gate),
               "pointer": int(args.pointer), "state": "MERGED",
               "tracker_mutation": "dispose(gate-approved)+unblock",
               "operator_approved": bool(args.operator_approved)}
    print(json.dumps(receipt, sort_keys=True))
    return 0


def build_parser():
    p = argparse.ArgumentParser(description="The sanctioned PR finisher (merge + optional guarded tail).")
    # The shared options live on a `parents=` parser attached to EACH subcommand, so the documented
    # subcommand-FIRST form parses: `idc_pr_finish.py autonomous --repo R --pr N --kind planning`
    # (with argparse, an option defined only on the PARENT parser must precede the subcommand — the
    # exact mismatch that made `autonomous --repo …` exit 2 `unrecognized arguments: --repo`).
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=".",
                        help="the governed repo root (gh infers owner/repo from its git remote)")
    common.add_argument("--backend", choices=["filesystem", "github"], default=None,
                        help="engine backend for the dispose/unblock tail (requirements mode)")
    common.add_argument("--tracker", default=None, help="TRACKER.md path (filesystem backend)")
    common.add_argument("--owner", default=None, help="github project owner (for the engine tail)")
    common.add_argument("--project", default=None, help="github project number (for the engine tail)")
    sub = p.add_subparsers(dest="mode", required=True)

    a = sub.add_parser("autonomous", parents=[common],
                       help="merge a planning/recirculation/intake PR (closes no tracker item)")
    a.add_argument("--pr", type=int, required=True)
    a.add_argument("--kind", choices=sorted(KIND_PREFIX), required=True)

    r = sub.add_parser("requirements", parents=[common],
                       help="merge the bound gate PR then guarded dispose-before-unblock")
    r.add_argument("--pr", type=int, required=True)
    r.add_argument("--gate", type=int, required=True)
    r.add_argument("--pointer", type=int, required=True)
    r.add_argument("--operator-approved", dest="operator_approved", action="store_true",
                   help="the operator gave an unambiguous in-session GO — required to merge a still-OPEN PR")
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    args.repo = os.path.abspath(args.repo)
    try:
        if args.mode == "autonomous":
            return cmd_autonomous(args)
        return cmd_requirements(args)
    except FinishError as e:
        sys.stderr.write(f"idc-pr-finish: {e}\n")
        return e.code


if __name__ == "__main__":
    sys.exit(main())
