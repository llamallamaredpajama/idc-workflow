#!/usr/bin/env python3
"""idc_autorun_drain.py — Autorun's drain predicate (`WORKFLOW.md §4.5`).

Autorun is the one-shot full-pipe drainer: it keeps claiming build work while any is
actionable and exits when nothing actionable remains (only Done items, requirements-gated
Blocked items, the operator's own gate issues, and un-admitted considerations left). This helper
computes the build lane's eligibility over the filesystem tracker — the deterministic exit
condition.

Eligible build work = an issue that is:
  * `Status = Todo`,
  * `Stage = Buildable` (or no Stage on a legacy 4-field repo) — claim ONLY Buildable; any
    non-Buildable stage is build-excluded by construction (the glass wall). An upstream pointer
    item (`Stage = Consideration`/`Planning`) and a `Stage = Recirculation` inbox item (scope
    discovered mid-build, drained by `/idc:recirculate`) are never scooped as build work. A
    `Stage = Consideration` pointer is a consideration **pending admission behind its Think PR**
    (the one gate), so it must never be built past until the operator merges that PR,
  * NOT an operator-action gate issue (title starting with `[operator-action]`), and
  * has every native blocked-by upstream `Done`.

Prints the eligible issue numbers, two whole-pipe fixpoint counts (`recirc_inbox: N` = open
`Stage=Recirculation ∧ Status=Todo` inbox tickets; `unplanned_considerations: M` = admitted-but-
unplanned `Stage=Consideration ∧ Status=Todo` pointers — both always printed), and a verdict:
`drain: continue` (build work remains), `drain: complete` (nothing actionable left anywhere — exit),
`drain: recirc-pending` + exit 4 (the build lane IS drained — nothing eligible — but N>0 or M>0, so
the pipe is NOT at a whole-pipe fixpoint: the top-of-pipe inbox still owes a `/idc:recirculate` drain
or a planning pass. A DISTINCT non-zero verdict so autorun does NOT treat it as terminal `complete`;
it drains the inbox / plans the consideration next `/loop`, then re-checks), `drain: unknown` + exit 2
(the github board read SUCCEEDED but NO eligible work remains AND ≥1 build candidate's blocked-by
lookup was unverifiable, so the lane cannot be proven drained — autorun must NOT treat this as
`complete`/terminal, the silent blind-drain this guards; it retries next `/loop`; this precedes the
recirc-pending branch — an unprovable build lane is the stronger signal), or
`drain: rate-limited until <reset>` + exit 3 (github only,
#99 §C.3 — the board read hit `idc_gh_board`'s `RateLimitError`: GitHub's GraphQL quota is exhausted,
NOT a hard failure and NOT nothing-actionable. A DISTINCT signal from both `drain: unknown` and a
hard board-read failure so autorun treats it as a deliberate, resumable pause — never a silent drop,
never `complete` — and re-checks the SAME still-actionable lane next `/loop`, once past `<reset>`).
For build ELIGIBILITY (`drain: continue`/`complete`) this helper covers the build lane / board-exit
half — the planning lane's actual DRAINING (turning admitted considerations into buildable waves) is
still the orchestrator's job. The helper only COUNTS the top-of-pipe inbox (`recirc_inbox` /
`unplanned_considerations`) to gate the whole-pipe fixpoint verdict (`drain: recirc-pending`); it
never itself recirculates or plans.

With `--width`, one extra line reports the ready frontier's width:
  width: <N>     (the cardinality of the `eligible:` set already printed above)
Width is the max-useful parallelism the CURRENT ready frontier can staff — the size of the unblocked
eligible antichain (Wave is never consulted, so different waves do not partition it; a blocked
dependent and a glass-wall Consideration/Planning pointer are excluded by the same eligibility
predicate). Autorun's parent reads it as the sous-chef count feeding the launch-time staffing
estimate — one `--width` call reports the frontier right now; the cross-`/loop` estimate sums these
across iterations, not a single invocation. The flag is opt-in so the default output stays
byte-identical for existing callers (the ready set is always on the `eligible:` line, with or without it).

Backends (the SAME pure predicate over either source — `compute_eligible`):
  * filesystem — `--tracker <TRACKER.md>` (the default): the issues ride the tracker state block.
  * github     — `--backend github --project <n> --owner <o> [--repo <dir>]`: ALL board items via
    the shared paginating reader (`idc_gh_board`), with native blocked_by resolved per build
    candidate. The github build lane has no other executable exit condition — agents MUST consume
    this helper instead of improvising a (truncation-prone) `gh project item-list`.

Usage: idc_autorun_drain.py --tracker <TRACKER.md> [--width]                       (filesystem)
       idc_autorun_drain.py --backend github --project <n> --owner <o> [--width]   (github)
       (exit 0 = ok/complete/continue, 2 = error/unknown, 3 = rate-limited — resumable pause,
        github only, 4 = recirc-pending — build lane drained but the Recirculation/Consideration
        inbox is non-empty, NOT terminal)
"""
import argparse
import json
import os
import re
import subprocess
import sys

BEGIN = "<!-- idc-tracker-state:begin -->"
END = "<!-- idc-tracker-state:end -->"


def load(path):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    m = re.search(re.escape(BEGIN) + r"\s*```json\s*(.*?)\s*```\s*" + re.escape(END), text, re.S)
    if not m:
        sys.stderr.write(f"idc-autorun-drain: no tracker state block in {path}\n")
        sys.exit(2)
    state = json.loads(m.group(1))
    if not isinstance(state, dict):
        sys.stderr.write(f"idc-autorun-drain: tracker state block is not a JSON object in {path}\n")
        sys.exit(2)
    return state


def load_filesystem(path):
    """Load + validate the filesystem TRACKER.md, returning the (guarded) issues list.

    Keeps the fail-closed corruption guards verbatim — a MISSING `issues` key is corruption (e.g. a
    github bug that drops it), not an empty board, so fail closed rather than read it as zero issues
    and print `drain: complete`; an explicit `issues: []` is still a legitimate empty board. Every
    entry must be a dict (membership tests, `.get()`, the sort key, and `.startswith()` all assume
    it), `number` must be an int (it is a dict key AND a sort key — an unhashable/unsortable value
    would crash instead of exiting 2), and `blocked_by` must be a list (the predicate iterates it).
    A scalar entry, a non-int number, or a non-list blocked_by exits 2 with a clean diagnostic — the
    same fail-closed contract the sibling idc_acceptance_check.py applies to its own fields."""
    try:
        state = load(path)
    except (OSError, json.JSONDecodeError) as e:
        sys.stderr.write(f"idc-autorun-drain: cannot read {path}: {e}\n")
        sys.exit(2)
    if "issues" not in state:
        sys.stderr.write("idc-autorun-drain: corrupt tracker — state block has no `issues` key\n")
        sys.exit(2)
    issues = state["issues"]
    if not isinstance(issues, list):
        sys.stderr.write("idc-autorun-drain: corrupt tracker — `issues` must be a list\n")
        sys.exit(2)
    for it in issues:
        if not isinstance(it, dict):
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue is not an object\n")
            sys.exit(2)
        if "number" not in it:
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue is missing `number`\n")
            sys.exit(2)
        if not isinstance(it["number"], int):
            sys.stderr.write("idc-autorun-drain: corrupt tracker — an issue `number` must be an int\n")
            sys.exit(2)
        if not isinstance(it.get("blocked_by", []), list):
            sys.stderr.write(
                f"idc-autorun-drain: corrupt tracker — issue {it['number']} `blocked_by` must be a list\n")
            sys.exit(2)
    return issues


def _is_build_candidate(it):
    """The status/stage/title half of the drain predicate — an issue that COULD be eligible build
    work before the blocked-by check:
      * Status == Todo,
      * (stage or "Buildable") == "Buildable" — claim ONLY Buildable; any non-Buildable stage
        (Consideration/Planning, or a Recirculation inbox item) is build-excluded by construction
        (the glass wall). An empty/missing Stage reads as Buildable (the legacy 4-field default),
      * title does not start with "[operator-action]" (the operator's gate issue, not build work).
    Shared by `compute_eligible` and the github loader's candidate pre-filter so the two can't drift."""
    return (it.get("status") == "Todo"
            and (it.get("stage") or "Buildable") == "Buildable"
            and not str(it.get("title", "")).strip().startswith("[operator-action]"))


def _inbox_count(issues, stage):
    """Count the `Stage == <stage> ∧ Status == Todo` items — a whole-pipe fixpoint conjunct.

    Two callers: `recirc_inbox` (stage="Recirculation" — scope discovered mid-build, awaiting
    /idc:recirculate) and `unplanned_considerations` (stage="Consideration" — an admitted pointer
    the planning lane still owes a decomposition). Both compute from the ALREADY-LOADED `issues`
    list (no second board read — the GraphQL-budget constraint), symmetric with
    `_is_build_candidate` so the build-lane and inbox predicates read the same source of truth."""
    return sum(1 for it in issues
               if it.get("stage") == stage and it.get("status") == "Todo")


def compute_eligible(issues):
    """PURE drain predicate — the deterministic exit condition, IDENTICAL across both backends.

    `issues` is a list of dicts with keys number/status/stage/title/blocked_by. An issue is eligible
    build work iff it is a build candidate (`_is_build_candidate`) AND every native blocked_by upstream
    is Done. Returns the eligible issue numbers sorted ascending. Kept side-effect-free so a hermetic
    unit test pins it over a >30-item fixture whose ready frontier sits past the old 30-item page."""
    status_by_num = {it["number"]: it.get("status") for it in issues}
    eligible = []
    for it in sorted(issues, key=lambda x: x["number"]):
        if not _is_build_candidate(it):
            continue
        if all(status_by_num.get(b) == "Done" for b in it.get("blocked_by", [])):
            eligible.append(it["number"])
    return eligible


def _blocked_by_numbers(repo, number):
    """The native blocked-by issue numbers for one issue, via the GitHub dependencies API.

    Uses gh's literal `{owner}/{repo}` placeholders (resolved from the repo in `cwd`), the same read
    counterpart of the documented write endpoint that doctor Row 9 uses. Returns (numbers, ok). On
    any gh failure ok is False — the caller fail-CLOSES (treats the issue as still-blocked this pass)
    so the drain never claims work whose blockers it could not verify; the next /loop iteration
    re-checks. Mirrors doctor Row 9's tri-state (a failed lookup ≠ no link)."""
    try:
        p = subprocess.run(
            ["gh", "api", f"repos/{{owner}}/{{repo}}/issues/{number}/dependencies/blocked_by",
             "--jq", "[.[].number]"],
            cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError):
        return [], False
    if p.returncode != 0:
        return [], False
    try:
        nums = json.loads(p.stdout or "[]")
    except json.JSONDecodeError:
        return [], False
    return [n for n in nums if isinstance(n, int)], True


def load_github(owner, project_number, repo):
    """Build the predicate's issues list from the github board (ALL pages via idc_gh_board).

    Returns `(issues, unverified)` where `unverified` is the count of build candidates whose native
    blocked_by lookup FAILED this pass. Normalizes each issue-backed item to number/status/stage/title,
    then resolves native blocked_by ONLY for the build-candidate lane (Todo + Buildable +
    non-operator-action) — the only issues whose blocker state can change eligibility, so
    non-candidates skip the per-issue API call. A blocked_by lookup failure fail-closes the candidate
    (an unresolvable sentinel blocker) so it is excluded this pass, never claimed unverified — AND is
    tallied into `unverified` so the AGGREGATE verdict (main) can refuse a false `drain: complete` when
    nothing is eligible only because every candidate's blockers were unverifiable. Exits 2 on an
    unreadable board (fail-closed, never a hollow empty drain), or 3 on a RATE-LIMITED board read (see
    below) — never a hollow empty drain, and never conflated with a hard failure either."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — github-only dependency, imported lazily
    try:
        items = idc_gh_board.fetch_items(owner, project_number, repo)
    except idc_gh_board.RateLimitError as e:
        # Resumable pause (#99, design §C.3) — CAUGHT BEFORE the generic BoardReadError branch below
        # (RateLimitError is a subclass; order matters). A DISTINCT verdict from both `drain: unknown`
        # and a hard board-read failure: GitHub's GraphQL quota is exhausted, not broken, so autorun's
        # `/loop` must pause and re-check the SAME lane next iteration rather than silently drop the
        # tail wave or report the run drained. Exit 3 mirrors idc_gh_board's own rate-limit exit code
        # (0 ok / 2 hard-error-or-unknown / 3 rate-limited) so the convention stays consistent across
        # every github-backend helper. NOT `idc_gh_board.emit_rate_limit_verdict` — that verdict is the
        # bare 'rate-limited until <reset>' with no `drain:` prefix; this predicate's other verdicts
        # (`drain: continue`/`complete`/`unknown`) all carry one, and downstream `/loop` parsing pins it.
        print(f"drain: rate-limited until {e.reset}")
        sys.exit(3)
    except idc_gh_board.BoardReadError as e:
        sys.stderr.write(f"idc-autorun-drain: could not read the github board: {e}\n")
        sys.exit(2)
    issues = []
    for it in items:
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:                  # a draft item carries no issue number
            continue
        issues.append({
            "number": number,
            "status": it.get("status"),
            "stage": it.get("stage"),
            "title": content.get("title") or "",
        })
    unverified = 0
    for it in issues:
        if not _is_build_candidate(it):
            it["blocked_by"] = []
            continue
        nums, ok = _blocked_by_numbers(repo, it["number"])
        if not ok:
            unverified += 1
            sys.stderr.write(
                f"idc-autorun-drain: blocked_by lookup failed for #{it['number']} — "
                "excluded this pass (will retry next /loop)\n")
            it["blocked_by"] = [0]          # 0 is never a real issue number → never Done → excluded
        else:
            it["blocked_by"] = nums
    return issues, unverified


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=("filesystem", "github"), default="filesystem",
                    help="tracker backend (default: filesystem)")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem backend)")
    ap.add_argument("--project", help="integer project number (github backend)")
    ap.add_argument("--owner", help="project owner login (github backend)")
    ap.add_argument("--repo", default=".",
                    help="repo dir to run gh in (github backend; default cwd)")
    ap.add_argument("--width", action="store_true",
                    help="also print the ready frontier's width (max-useful parallelism); the ready set is the `eligible:` line")
    args = ap.parse_args()

    unverified = 0
    if args.backend == "github":
        if not args.project or not args.owner:
            sys.stderr.write("idc-autorun-drain: --project and --owner are required for the github backend\n")
            sys.exit(2)
        issues, unverified = load_github(args.owner, args.project, os.path.abspath(args.repo))
    else:
        if not args.tracker:
            sys.stderr.write("idc-autorun-drain: --tracker is required for the filesystem backend\n")
            sys.exit(2)
        issues = load_filesystem(args.tracker)

    eligible = compute_eligible(issues)
    recirc_inbox = _inbox_count(issues, "Recirculation")
    unplanned = _inbox_count(issues, "Consideration")

    print("eligible: " + " ".join(str(n) for n in eligible))
    # The two whole-pipe fixpoint counts, ALWAYS printed (like `eligible:`) so the signal is visible
    # on every run — build eligibility (`eligible:`) is only one of the three drain conjuncts.
    print("recirc_inbox: " + str(recirc_inbox))
    print("unplanned_considerations: " + str(unplanned))
    # AGGREGATE fail-closed verdict (the github blind-drain guard): NO eligible work remains AND at
    # least one build candidate's blocked_by lookup was unverifiable — so we CANNOT prove the build
    # lane is drained. Emitting `drain: complete` here would recreate the silent false-clean this whole
    # fix repudiates (autorun treats `complete` as TERMINAL and stops). Report `drain: unknown` + exit 2
    # so autorun retries next `/loop` instead, and skip the width line (the frontier is unknowable). (A
    # NON-EMPTY eligible set is safe to `continue` on — the unverifiable candidates simply retry next
    # loop. The filesystem path never sets `unverified`, so its verdict is unchanged.) This precedes the
    # recirc-pending branch: an unprovable build lane is a stronger signal than a non-empty inbox.
    if not eligible and unverified:
        print("drain: unknown")
        sys.exit(2)
    # WHOLE-PIPE fixpoint (the second/third conjuncts): the build lane is drained (nothing eligible)
    # but the Recirculation inbox or the admitted-but-unplanned consideration lane still owes upstream
    # work — the pipe is NOT at a fixpoint. A DISTINCT non-zero verdict (`drain: recirc-pending` + exit
    # 4) so autorun does not treat this as terminal `complete`: the next /loop drains the inbox
    # (/idc:recirculate) / plans the consideration, then re-checks. Both backends share it (the counts
    # come from the same already-loaded `issues`). Skip the width line — the build frontier is empty here.
    if not eligible and (recirc_inbox or unplanned):
        print("drain: recirc-pending")
        sys.exit(4)
    print("drain: " + ("continue" if eligible else "complete"))
    if args.width:
        # The ready frontier IS the `eligible:` set already printed above; width is its size = the
        # unblocked eligible antichain that can be staffed in parallel right now (the sous-chef
        # count; Wave is never consulted). No `ready-frontier:` line — it would byte-duplicate
        # `eligible:`; consumers read the ready set from `eligible:` and the count from here.
        print("width: " + str(len(eligible)))


if __name__ == "__main__":
    main()
