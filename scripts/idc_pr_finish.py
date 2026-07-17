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
      approval when still open) and then run the guarded dispose-before-unblock.
      Two legal paths:
        * PR already MERGED — re-verify the gate carries EXACTLY ONE idc-gate-pr body marker naming
          THIS PR, then `idc_transition.py dispose --disposition gate-approved --num G`, then finish
          pointer P through the guarded `idc_gate_repair.py --finish-pointer` door.
        * PR OPEN — require --operator-approved (IDC never infers human approval), merge the bound PR,
          re-verify MERGED, then the SAME dispose-before-unblock tail.
      It EXITS before any tracker mutation if the PR is unmerged (no --operator-approved), markerless,
      double-marked, or bound to another PR; and if the dispose fails it does NOT unblock.
      The pointer step is the guarded DOOR, never the engine's raw `unblock`: `unblock --by` drops
      only the NAMED edge before setting Todo, so a pointer Blocked by [gate, other] would sail past
      `other` without `other`'s proof. When other blockers remain the dispose STANDS (the approval was
      verified — that Done is honest) but the unblock is REFUSED, and this exits NONZERO naming the
      remainders, with the pointer left Blocked; re-run once they resolve and it converges.

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
GATE_REPAIR = os.path.join(HERE, "idc_gate_repair.py")

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
    """Squash-merge + delete the branch atomically (never GitHub --auto), then confirm MERGED.

    Robust to a NONZERO merge CLI result (round-5 Fix 6): the server can merge the PR and THEN fail a
    later branch-cleanup step, returning nonzero — so we re-read PR state EVEN when `gh pr merge`
    errors, and treat a PR that reads MERGED as success. Only a PR that is NOT merged after the attempt
    is a real failure (the CLI error, if any, is surfaced). Returns (info, branch_deleted): a clean
    merge exit deletes the branch atomically → True; a nonzero exit after a server-side merge means the
    branch-delete step did not complete → False (reported, never silently dropped)."""
    merge_err = None
    try:
        _gh(["pr", "merge", str(int(pr)), "--squash", "--delete-branch"], repo)
    except FinishError as e:
        merge_err = e
    after = pr_view(repo, pr, ["state", "mergedAt"])
    if not _is_merged(after):
        # Genuinely not merged — surface the CLI error if there was one, else a plain non-MERGED state.
        raise merge_err or FinishError(
            f"PR #{pr} did not reach MERGED after the squash-merge (state={after.get('state')!r})")
    branch_deleted = merge_err is None   # nonzero exit after a server merge = the branch delete failed
    return after, branch_deleted


def _forward(script, args):
    """The shared flag-forwarding for the sibling doors this finisher shells out to: the governed repo
    plus whatever backend/tracker/owner/project the caller passed."""
    cmd = [sys.executable, script, "--repo", args.repo]
    if args.backend:
        cmd += ["--backend", args.backend]
    if args.tracker:
        cmd += ["--tracker", args.tracker]
    if args.owner:
        cmd += ["--owner", args.owner]
    if args.project:
        cmd += ["--project", str(args.project)]
    return cmd


def _transition(args, extra):
    """Run the engine (idc_transition.py) as the single write door for the dispose. A non-zero engine
    exit raises FinishError carrying the engine's exit code (2 denied / 3 resumable), so a refused
    dispose stops the tail BEFORE the pointer is finished."""
    r = subprocess.run(_forward(TRANSITION, args) + extra, capture_output=True, text=True)
    if r.returncode != 0:
        raise FinishError(f"engine op {' '.join(extra)} failed (exit {r.returncode}): "
                          f"{r.stderr.strip()[:200]}", code=r.returncode if r.returncode in (2, 3) else 2)
    return r.stdout


def _finish_pointer(args, apply_):
    """Finish the gate's pointer through the GUARDED pointer-finish door — never the engine's raw
    `unblock`. Returns the door's plan dict.

    WHY THE DOOR. The engine's `unblock --by` removes the NAMED edge and then sets Todo; it never
    looks at what ELSE blocks the pointer. This tail is the mechanized executor that
    `idc:idc-gate-issue`'s step 4 recommends, so a raw unblock HERE would admit a pointer Blocked by
    `[gate, other]` past `other` WITHOUT `other`'s proof — and Autorun treats an unblocked
    Consideration pointer as approved work. That is exactly the admission
    `idc_gate_repair.py --finish-pointer` refuses (it re-reads the gate's on-disk proof AND requires
    the proven gate to be the SOLE remaining blocker). The rule lives in that ONE door; a guard the
    door keeps but its recommended executor skips is not a guard, so this routes through it instead of
    re-implementing the check here.

    DRY RUN FIRST, THEN `--apply` — the door's own documented contract. The dry run is ADVISORY only:
    it yields the structured plan whose `other_blockers` this finisher's receipt reports, while
    `--apply` re-reads every precondition itself. The door stays the only decider.
    """
    cmd = _forward(GATE_REPAIR, args) + ["--finish-pointer", "--gate", str(int(args.gate)),
                                         "--pointer", str(int(args.pointer)), "--json"]
    if apply_:
        cmd.append("--apply")
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise FinishError(f"pointer-finish refused for #{args.pointer}: {r.stderr.strip()[:400]}",
                          code=r.returncode if r.returncode in (2, 3) else 2)
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        raise FinishError(f"could not parse the pointer-finish plan for #{args.pointer} ({e})")


def _pointer_step(plan):
    """The door's pointer step: its `status` is the real outcome (applied / satisfied / refused) and
    its `other_blockers` name the remainders a refusal is protecting."""
    for step in plan.get("steps") or []:
        if step.get("id") == "unblock-pointer":
            return step
    return {}


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
    _, branch_deleted = _merge_pr(args.repo, args.pr)
    receipt = {"op": "pr-finish", "mode": "autonomous", "kind": args.kind, "pr": int(args.pr),
               "head": head, "state": "MERGED", "branch_deleted": branch_deleted,
               "tracker_mutation": "none"}
    print(json.dumps(receipt, sort_keys=True))
    return 0


# ── requirements: merge the bound gate PR (with approval) then dispose-before-unblock ─────────────
def _nums(nums):
    return " + ".join(f"#{int(n)}" for n in nums)


def _receipt(args, branch_deleted, unblock, remaining):
    """The requirements receipt. `unblock` carries the pointer step's REAL outcome (applied /
    satisfied / refused) and `remaining_blockers` names why a refusal held — a receipt that reported
    only the dispose would read as a finished admission while the pointer sits Blocked."""
    return {"op": "pr-finish", "mode": "requirements", "pr": int(args.pr), "gate": int(args.gate),
            "pointer": int(args.pointer), "state": "MERGED", "branch_deleted": branch_deleted,
            "tracker_mutation": ("dispose(gate-approved)+unblock" if unblock == "applied"
                                 else "dispose(gate-approved)"),
            "unblock": unblock, "remaining_blockers": remaining,
            "operator_approved": bool(args.operator_approved)}


def _bound_pr(args):
    """The gate's own recorded approval PR: EXACTLY ONE idc-gate-pr body marker, naming THIS --pr.
    Refuses a markerless / double-marked / other-PR-bound gate BEFORE any tracker mutation."""
    info = issue_view(args.repo, args.gate, ["body"])
    prs = GATE_PR_MARKER.findall(info.get("body") or "")
    if not prs:
        raise FinishError(f"requirements: gate #{args.gate} carries no idc-gate-pr body marker (markerless) "
                          "— migrate it through idc_pr_gate_bind.py so both reciprocal bodies are "
                          "validated and read back, then re-run")
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
    branch_deleted = None   # only a merge THIS run has a branch-deletion outcome to report
    if not _is_merged(info):
        # OPEN path: an explicit in-session operator approval is REQUIRED (IDC never infers it).
        if not args.operator_approved:
            raise FinishError(f"requirements: PR #{args.pr} is not merged and --operator-approved was not "
                              "given — IDC never infers human approval; leave the gate Blocked and move on")
        if info.get("state") != "OPEN":
            raise FinishError(f"requirements: PR #{args.pr} is {info.get('state')!r}, neither MERGED nor OPEN")
        if info.get("mergeable") != "MERGEABLE":
            raise FinishError(f"requirements: PR #{args.pr} is not mergeable (mergeable={info.get('mergeable')!r})")
        _, branch_deleted = _merge_pr(args.repo, args.pr)
    # MERGED confirmed → the guarded dispose-before-unblock tail (dispose FIRST; if it fails, no unblock).
    _transition(args, ["dispose", "--disposition", "gate-approved", "--num", str(int(args.gate))])

    # The pointer goes through the guarded door (see _finish_pointer): read its plan, then apply.
    # The branch turns on the door's OWN verdict, never on a re-reading of its inputs — a pointer that
    # is already Todo reads `satisfied` (an honest no-op) even if a stale edge lingers, and only the
    # door decides that.
    planned = _pointer_step(_finish_pointer(args, False))
    remaining = ([int(n) for n in (planned.get("other_blockers") or [])]
                 if planned.get("status") == "refused" else [])
    if remaining:
        # The dispose STANDS — its approval was verified, so the gate's Done is honest and rolling it
        # back to hide this would itself be false history. Only the unblock is refused. Report exactly
        # that (naming the remainders) and exit NONZERO: reporting success would hide a pointer left
        # Blocked, and the caller must surface undone work.
        print(json.dumps(_receipt(args, branch_deleted, "refused", remaining), sort_keys=True))
        raise FinishError(
            f"requirements: gate #{args.gate} is disposed (its approval was verified — that Done is "
            f"real and stands), but the pointer-finish door REFUSED #{args.pointer}: it is also "
            f"blocked by {_nums(remaining)}, and the engine's `unblock --by` would drop only gate "
            f"#{args.gate}'s edge and then set Todo — admitting it past {_nums(remaining)} without "
            f"their proof. #{args.pointer} is left Blocked. Resolve {_nums(remaining)} through their "
            "own doors, then re-run this command to converge.")
    outcome = _pointer_step(_finish_pointer(args, True)).get("status") or "applied"
    print(json.dumps(_receipt(args, branch_deleted, outcome, []), sort_keys=True))
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
