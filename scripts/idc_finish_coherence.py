#!/usr/bin/env python3
"""idc_finish_coherence.py — the ONE reader that answers "is the board still claiming work that has
already shipped?" (`WORKFLOW.md §4.3`).

THE FAILURE THIS EXISTS FOR. `idc_git_finish.py` merges the triplet's PR at its step 3
(`idc_git_finish.py::main`, the `pr_merge` call) and flips the board to `Done` three steps later
(`tracker_close`). Merging is ALSO what closes the linked issue — IDC mandates an unbackticked
`Closes #N` in the PR body precisely so GitHub auto-closes it (the RC3 fix,
`tests/smoke/phase7-closing-keywords.sh`). So the merge is a point of no return that closes the issue
as a SIDE EFFECT, while the board flip is a separate later call in the same process. A session that
dies in that window — context exhaustion, a kill, a `gh` failure on the branch-delete step — leaves
exactly: **PR merged · issue closed · board still `In Progress`**. The board then advertises active
work that actually shipped. Seven items in one governed repo landed in precisely this state
(`docs/dev/2026-07-19-completion-honesty.md`).

WHY A NEW READER, GIVEN THE DETECTOR ALREADY EXISTS. It does, and it is exact:
`idc_git_janitor.board_coherence_verdict` classifies "board Status is not Done but a merged PR closed
the issue" as a SAFE-FIX `set-done` (and the filesystem analog "its IDC build branch merged" as
`close-fs`). What did NOT exist is any path on which that finding can FAIL anything: the janitor is
operator-invoked, autorun's janitor preflight is report-only-and-advisory by default, doctor Row 10 is
declared never-FAIL, and the drain predicate never reads the signal at all — so it printed
`drain: complete` over a lying board. This module is the enforcement seam, NOT a second detector: it
REUSES the janitor as the single source of the coherence verdict and only isolates the one finding
class, so the two can never drift apart.

WHY THE FILTER IS LOAD-BEARING. The janitor exits 1 on ANY finding of ANY tier — including
REPORT-ONLY foreign-tool debris (a stray Codex worktree) that is explicitly none of IDC's business.
Gating a drain on the janitor's raw exit code would halt honest work over unrelated noise, which is
how a gate gets disabled. So this reader selects EXACTLY the ops that mean "reality moved on and the
board did not" — `set-done` and `close-fs` — and is silent about everything else the janitor found.
Deliberately EXCLUDED: the janitor's RISKY `reconcile` op (issue CLOSED as NOT_PLANNED — abandoned,
not completed). Stamping that `Done` would be a judgment call, and this gate only ever reports
mechanically-provable staleness.

FAIL-CLOSED, and the distinction matters (mirrors `idc_gate_proof.py`): "the board is coherent" and "I
could not establish whether the board is coherent" are different answers. An unreadable board, a
janitor that could not establish ground truth, a scan that was never given board arguments, a
missing/crashed helper, or unparseable JSON all yield exit 2 (INDETERMINATE) — never a clean exit 0.
A hollow clean here would re-create the exact silent false-clean this module exists to remove.

Exit contract (the sibling-helper convention — see idc_acceptance_check.py). The verdict WORD is
deliberately `gap`, matching `acceptance: gap` and `live: gap` rather than a more descriptive
"stale": all three wave-close checks are read by ONE classifier in idc_autorun_drain.py, and a check
that invents its own word for "finding" gets classified as an ERROR — reported as "I could not tell"
when the truth is precisely known. The description belongs in the detail line, not the verdict token.
  exit 0  `finish-coherence: ok`             — every shipped item's board Status agrees with reality.
  exit 0  `finish-coherence: not-applicable` — the repo is not a git repository, so the failure class
                                               this gate detects cannot exist here (see below).
  exit 1  `finish-coherence: gap #a #b …`    — those items shipped but the board was never flipped.
  exit 2  `finish-coherence: error <why>`    — ground truth could not be established (INDETERMINATE).

INAPPLICABLE IS NOT THE SAME AS INDETERMINATE, and conflating them would make this gate useless in
practice. "The scan ran and could not establish ground truth" (a degraded or truncated board read that
may be MASKING stale items) must fail closed. But "this is not a git repository" is a different claim:
with no git there are no branches, no PRs and no merges, so there is no such thing as work that
shipped, and therefore nothing the board can be stale ABOUT. Reporting INDETERMINATE there would mark
such a repo permanently unfinishable — the drain could never honestly say `complete` again — which is
how a gate earns a reputation for crying wolf and gets switched off. So that ONE case is answered
`not-applicable` and treated as clean. Every other failure to establish ground truth still exits 2.

This module NEVER mutates. The repair runs through the doors that already exist — the idempotent
`idc_git_finish.py --close-only` per item, or `/idc:janitor --apply-safe` for the batch — both of
which journal the close. Reporting and repairing stay separate on purpose: a detector that also
mutates cannot be run freely by a gate.

Usage:
  idc_finish_coherence.py --repo <dir> --tracker <TRACKER.md>                   (filesystem)
  idc_finish_coherence.py --repo <dir> --backend github --owner <o> --project <n>   (github)
"""
import argparse
import json
import os
import subprocess
import sys

# The janitor ops that mean "the work shipped but the board still says otherwise" — the ONLY findings
# this gate speaks for. `set-done` is the github verdict (a merged PR closed the issue, or the issue is
# CLOSED as COMPLETED, while Status != Done); `close-fs` is the filesystem analog (the item's IDC build
# branch merged while Status != Done). Both are the janitor's SAFE-FIX tier — deterministic, no judgment.
STALE_OPS = ("set-done", "close-fs")

JANITOR = "idc_git_janitor.py"
# The janitor's own documented exit contract: 0 coherent · 1 findings (any tier) · 2 ground truth not
# established. Anything OUTSIDE this set means the janitor itself crashed (an uncaught traceback exits
# 1 — which is why the JSON verdict, not the exit code alone, decides below).
_JANITOR_EXITS = (0, 1, 2)


def _fail(reason):
    """INDETERMINATE — print the machine-readable error line and exit 2 (never a hollow clean)."""
    print(f"finish-coherence: error {reason}")
    sys.exit(2)


def stale_numbers(report):
    """The sorted item numbers the janitor report flags as shipped-but-not-Done.

    `report` is the janitor's parsed `--json` object. Raises ValueError on a shape this cannot trust —
    the caller turns that into exit 2 rather than an empty (falsely clean) list.
    """
    if not isinstance(report, dict):
        raise ValueError("janitor JSON is not an object")
    findings = report.get("findings")
    if not isinstance(findings, list):
        raise ValueError("janitor JSON has no `findings` list")
    nums = set()
    for f in findings:
        if not isinstance(f, dict):
            raise ValueError("a janitor finding is not an object")
        if f.get("op") not in STALE_OPS:
            continue
        num = f.get("number")
        # A stale-class finding with no usable number cannot be named in the verdict line, and
        # silently dropping it would under-report staleness. Fail closed instead.
        if type(num) is not int or num <= 0:
            raise ValueError(f"a {f.get('op')!r} finding carries no usable item number ({num!r})")
        nums.add(num)
    return sorted(nums)


def run_janitor(args):
    """Run the janitor in its read-only JSON mode and return its parsed report.

    Never passes `--apply-safe`: this reader is a detector, and a gate that mutates as a side effect of
    being consulted is not one anybody can afford to run often.
    """
    janitor = os.path.join(os.path.dirname(os.path.abspath(__file__)), JANITOR)
    if not os.path.isfile(janitor):
        _fail(f"{JANITOR} not found next to this helper")
    cmd = [sys.executable, janitor, "--repo", args.repo, "--json"]
    if args.backend == "github":
        if not args.owner or not args.project:
            _fail("--owner and --project are required for the github backend")
        cmd += ["--backend", "github", "--owner", args.owner, "--project", str(args.project)]
    else:
        if not args.tracker:
            _fail("--tracker is required for the filesystem backend")
        cmd += ["--tracker", args.tracker]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout)
    except subprocess.TimeoutExpired:
        _fail(f"{JANITOR} timed out after {args.timeout}s")
    except (OSError, subprocess.SubprocessError) as e:
        _fail(f"{JANITOR} could not be run ({e})")
    if r.returncode not in _JANITOR_EXITS:
        _fail(f"{JANITOR} exited {r.returncode}, outside its documented contract "
              f"{_JANITOR_EXITS} — its verdict cannot be trusted")
    try:
        report = json.loads(r.stdout or "")
    except json.JSONDecodeError as e:
        _fail(f"{JANITOR} emitted unparseable JSON ({e})")
    return report


def main(argv=None):
    ap = argparse.ArgumentParser(
        prog="idc_finish_coherence.py",
        description="Report items whose work has shipped (PR merged / issue closed as completed) but "
                    "whose board Status was never flipped to Done. Read-only; fail-closed.")
    ap.add_argument("--repo", default=".", help="the governed repo root (default: cwd)")
    ap.add_argument("--backend", choices=("filesystem", "github"), default="filesystem",
                    help="tracker backend (default: filesystem)")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem backend)")
    ap.add_argument("--owner", help="project owner login (github backend)")
    ap.add_argument("--project", help="integer project number (github backend)")
    ap.add_argument("--timeout", type=int, default=180,
                    help="seconds to allow the janitor scan (default: 180)")
    args = ap.parse_args(argv)
    args.repo = os.path.abspath(args.repo)

    # INAPPLICABILITY CHECK, before anything expensive. Without git there are no branches, PRs or
    # merges — so no work can have "shipped", and the board cannot be stale about it. The janitor would
    # exit 2 here (it needs a git repo to establish ground truth), and reporting that as INDETERMINATE
    # would leave such a repo permanently unable to reach an honest `drain: complete`.
    try:
        r = subprocess.run(["git", "-C", args.repo, "rev-parse", "--git-dir"],
                           capture_output=True, text=True, timeout=30)
        is_git = r.returncode == 0
    except (OSError, subprocess.SubprocessError) as e:
        _fail(f"git could not be run in {args.repo} ({e})")
    if not is_git:
        print("finish-coherence: not-applicable")
        sys.exit(0)

    report = run_janitor(args)

    # GROUND TRUTH FIRST. `board_scanned: false` means the janitor ran git-only — it never looked at a
    # board, so it could not have produced a single coherence finding. Reading that as "ok" is the
    # hollow clean this gate exists to prevent, and it is the likeliest misconfiguration (a caller that
    # forgot --tracker / --owner). Same for the janitor's own `indeterminate` verdict: a degraded or
    # capped read may be MASKING stale items.
    if report.get("board_scanned") is not True:
        _fail("the janitor did not scan a board (board_scanned=false) — coherence is unprovable")
    if report.get("verdict") == "indeterminate":
        _fail("the janitor could not establish ground truth (verdict=indeterminate) — a degraded or "
              "truncated read may be masking stale items")
    if report.get("verdict") not in ("coherent", "findings"):
        _fail(f"the janitor reported an unrecognized verdict {report.get('verdict')!r}")

    try:
        stale = stale_numbers(report)
    except ValueError as e:
        _fail(f"the janitor report could not be read ({e})")

    if stale:
        print("finish-coherence: gap " + " ".join(f"#{n}" for n in stale))
        # The remediation names EXISTING doors only — this module mints no write path of its own.
        #
        # IT MUST BE BACKEND-CORRECT. `idc_git_finish.py --close-only` resolves the merged PR's head
        # branch through `gh`, so it exists ONLY on the github backend; naming it to a filesystem repo
        # hands the operator a command that dies on a missing `gh` before it does anything. A gate that
        # reports a real problem and then points at a door that cannot open is worse than one that says
        # nothing, because the operator burns their trust on the instruction rather than the finding.
        batch = ("/idc:janitor --apply-safe (the batch door; it re-derives the same findings, so "
                 "running it twice applies nothing the second time and writes no second record)")
        if args.backend == "github":
            door = (f"per item: idc_git_finish.py --close-only --pr <N> --issue {stale[0]} — or "
                    f"{batch}")
        else:
            door = (f"{batch}. The per-item --close-only door needs a merged pull request, so it does "
                    f"not apply on the filesystem backend")
        sys.stderr.write(
            f"idc-finish-coherence: {len(stale)} item(s) shipped but the board never advanced. "
            f"Repair through the existing door — {door}. Then re-run this check; it is read-only and "
            f"safe to re-run.\n")
        sys.exit(1)
    print("finish-coherence: ok")
    sys.exit(0)


if __name__ == "__main__":
    main()
