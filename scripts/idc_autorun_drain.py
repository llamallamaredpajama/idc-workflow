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
        github only, 4 = recirc-pending / acceptance-gap / coherence-gap / live-gap — build lane
        drained but NOT terminal)

With `--acceptance` (opt-in, filesystem) the wave-close acceptance result GATES a would-be-`complete`
verdict (v4 Phase 3 Stage E3): a GAP (a merged-Done item is inert) becomes `drain: acceptance-gap` +
exit 4 (a new VERDICT TOKEN on the existing non-terminal exit 4 — the orchestrator recirculates the
inert items), and an ERROR (the check errored / exited 2 / was unrunnable — e.g. a corrupt tracker)
becomes `drain: unknown` + exit 2 (we cannot prove the wave clean → autorun retries next `/loop`). So a
corrupt or inert wave close can never masquerade as a clean, TERMINAL `complete`. The gate fires ONLY on
the would-be-`complete` path — an already-non-terminal verdict (unverified/unknown, recirc-pending)
still wins — and the Phase-0 exit-code SET {0,2,3,4} is unchanged.

`--coherence` and `--live` are two MORE wave-close gates of exactly that shape (both backends, both
opt-in, both new TOKENS on the existing exit 4). They exist because "the build lane is empty" was the
drain's whole definition of finished, and that definition is blind in two directions:

  * `--coherence` (`idc_finish_coherence.py`) — the drain counts only `Status = Todo`, so an item that
    SHIPPED but whose board Status was never advanced is invisible to every conjunct above. The finish
    tail merges the PR (which auto-closes the issue via the mandated `Closes #N`) several steps before
    it flips the board, so a session dying in that window strands the item at `In Progress` forever.
    The drain then printed terminal `complete` over a board advertising work that had already shipped,
    and the Stop gate cleared the orchestrator marker on the strength of it. A finding ⇒
    `drain: coherence-gap` exit 4; an indeterminate check ⇒ `drain: unknown` exit 2.
  * `--live` (`idc_live_check.py`) — every gate in the pipe verifies CODE. None of them can distinguish
    "all PRs merged and reviewed" from "the deployed product works", which is how a phase shipped with
    a dead ingest path and every gate green. A repo DECLARES its live surfaces; this gate requires
    current evidence each was driven. An undeclared repo reports `live: not-declared` and is never
    gated. A finding ⇒ `drain: live-gap` exit 4; an indeterminate check ⇒ `drain: unknown` exit 2.

Wiring them HERE rather than as new hooks is the whole point: exit 4 is already the code the Stop
fixpoint gate refuses a stop on, so both become enforceable without a new hook, a new exit code, or a
second definition of "finished".
"""
import argparse
import json
import os
import re
import subprocess
import sys

BEGIN = "<!-- idc-tracker-state:begin -->"
END = "<!-- idc-tracker-state:end -->"

# The wave-close coherence check's ceiling, in seconds. Exported so the Stop fixpoint gate — which
# re-runs this drain on its own stop path — can assert its own timeout is strictly LARGER and keep the
# safe degradation ordering described in _run_wave_close_coherence. A shared constant rather than two
# hardcoded numbers, because the ordering is the whole safety property and two literals drift.
COHERENCE_TIMEOUT = 120


def _persist_verdict(root, sid, verdict, exit_code):
    """Record THIS drain pass's `{verdict, exit, session_id}` to the local, gitignored
    `.idc-drain-verdict.json` at the workspace root (v4 Phase 3 Stage E2) so the Stop fixpoint gate's
    GITHUB branch can read it instead of re-running the drain live (zero new GraphQL on the stop path).

    ADDITIVE + BEST-EFFORT: this NEVER touches the drain's exit-code contract or stdout verdict lines
    (Stage B + Phase 0 depend on them) and NEVER raises — a persist failure (import error, repo not
    governed, write error) degrades silently to a stderr note so it can't break the drain. Backend-
    agnostic: written on both backends (the filesystem gate ignores it and keeps re-draining live; only
    the github gate consumes it). Last-write-wins: every pass overwrites, so the final `complete`
    supersedes any earlier `recirc-pending`.

    `root=None` is the explicit read-only observer mode used by the next-action oracle. Return before
    importing or entering any verdict/gitignore write path; observing state must never emit persistence
    diagnostics or mutate the caller's governed current directory."""
    if root is None:
        return
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks"))
        import idc_drain_verdict  # noqa: E402 — sidecar in scripts/hooks/, imported lazily
        idc_drain_verdict.write_verdict(root, verdict, exit_code, session_id=sid)
    except Exception as e:  # noqa: BLE001 — persistence is additive; it must never break the drain
        sys.stderr.write(f"idc-autorun-drain: verdict-persist skipped ({e})\n")


def _workspace_root(args):
    """The governed workspace root the verdict file lives at — the SAME dir the Stop gate reads as the
    Stop payload's `cwd`. github: the --repo dir; filesystem: the TRACKER.md's dir (repo-root/TRACKER.md
    in a governed repo). Absolute so the persist target is stable regardless of the drain's own cwd.

    LOAD-BEARING INVARIANT (MINOR-3, reviewer-E2): this root MUST equal the governed repo root the Stop
    fixpoint gate sees as its payload `cwd` — the drain persists here, the gate reads there, and they
    coincide only when the drain is invoked from / pointed at that same root. The shipped wiring
    guarantees it: autorun runs `idc_autorun_drain.py --repo "$PWD"` from the repo root and the Stop
    payload `cwd` is that same `$PWD`. A future caller that points `--repo` (or a filesystem `--tracker`)
    at a DIFFERENT tree than the gate's repo would silently strand the verdict where the gate never reads
    it → a permanent, error-free github false-defer. Keep the drain and the Stop gate rooted together."""
    if args.backend == "github":
        return os.path.abspath(args.repo)
    if args.tracker:
        return os.path.dirname(os.path.abspath(args.tracker))
    return os.getcwd()


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
    it), `number` must be a true positive int (it is a durable issue identity AND a sort key), and
    `blocked_by` must be a list of true positive integers. A scalar entry, a non-positive/non-int
    number, or a non-list/non-positive/non-int blocked_by exits 2 with a clean diagnostic — the same
    fail-closed contract the sibling idc_acceptance_check.py applies to its own fields."""
    try:
        state = load(path)
    except (OSError, UnicodeError, json.JSONDecodeError) as e:
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
        if type(it["number"]) is not int or it["number"] <= 0:
            sys.stderr.write(
                "idc-autorun-drain: corrupt tracker — an issue `number` must be a positive int\n")
            sys.exit(2)
        blocked_by = it.get("blocked_by", [])
        if not isinstance(blocked_by, list) or any(
                type(value) is not int or value <= 0 for value in blocked_by):
            sys.stderr.write(
                f"idc-autorun-drain: corrupt tracker — issue {it['number']} "
                "`blocked_by` must be a list of positive ints\n")
            sys.exit(2)
    return issues


def _is_operator_gate(it):
    """Whether an item is a human-owned gate, never an automated pipeline lane."""
    return str(it.get("title", "")).strip().startswith("[operator-action]")


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
            and not _is_operator_gate(it))


def _inbox_count(issues, stage):
    """Count the `Stage == <stage> ∧ Status == Todo` items — a whole-pipe fixpoint conjunct.

    Two callers: `recirc_inbox` (stage="Recirculation" — scope discovered mid-build, awaiting
    /idc:recirculate) and `unplanned_considerations` (stage="Consideration" — an admitted pointer
    the planning lane still owes a decomposition). Both compute from the ALREADY-LOADED `issues`
    list (no second board read — the GraphQL-budget constraint), symmetric with
    `_is_build_candidate` so the build-lane and inbox predicates read the same source of truth."""
    return sum(1 for it in issues
               if it.get("stage") == stage and it.get("status") == "Todo"
               and not _is_operator_gate(it))


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

    Reuses `idc_gh_board.blocked_by_numbers()` verbatim: that sanctioned reader paginates and rejects
    every malformed/non-positive dependency record. Returns (numbers, ok). On a non-rate read failure
    ok is False — the caller fail-CLOSES (treats the issue as still-blocked this pass). A rate limit
    remains the shared reader's distinct resumable exception and dominates the whole snapshot."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — reuse the strict paginated dependency reader
    try:
        return idc_gh_board.blocked_by_numbers(number, repo), True
    except idc_gh_board.RateLimitError:
        raise
    except idc_gh_board.MalformedBoardDataError:
        raise
    except idc_gh_board.BoardReadError:
        return [], False


def _reject_malformed_github_item(root, sid, detail):
    """Fail closed at the shared item-normalization boundary with one stable diagnostic."""
    _persist_verdict(root, sid, "board-read-error", 2)
    sys.stderr.write(f"idc-autorun-drain: malformed github board item: {detail}\n")
    sys.exit(2)


def load_github(owner, project_number, repo, root=None, sid=None, repository=None):
    """Build the predicate's issues list from the github board (ALL pages via idc_gh_board).

    Returns `(issues, unverified)` where `unverified` is the count of build candidates whose native
    blocked_by lookup FAILED this pass. Normalizes each issue-backed item to number/status/stage/title,
    then resolves native blocked_by ONLY for the build-candidate lane (Todo + Buildable +
    non-operator-action) — the only issues whose blocker state can change eligibility, so
    non-candidates skip the per-issue API call. A blocked_by lookup failure fail-closes the candidate
    (an unresolvable sentinel blocker) so it is excluded this pass, never claimed unverified — AND is
    tallied into `unverified` so the AGGREGATE verdict (main) can refuse a false `drain: complete` when
    nothing is eligible only because every candidate's blockers were unverifiable. Exits 2 on an
    unreadable board (fail-closed, never a hollow empty drain), or 3 on a RATE-LIMIT anywhere in the
    complete board/dependency read (see below) — never a hollow empty drain, and never conflated with
    a hard failure either."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — github-only dependency, imported lazily
    try:
        items = idc_gh_board.fetch_items(owner, project_number, repo)
        if repository is None and items:
            repository = idc_gh_board._current_repository(repo)
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
        # Persist the resumable-pause verdict (last-write-wins): overwriting a prior recirc-pending so
        # a stop during a rate-limit reads `rate-limited` (exit 3 → the gate allows), never a stale
        # block on a board we could no longer prove pending.
        _persist_verdict(root, sid, "rate-limited", 3)
        print(f"drain: rate-limited until {e.reset}")
        sys.exit(3)
    except idc_gh_board.BoardReadError as e:
        _persist_verdict(root, sid, "board-read-error", 2)
        sys.stderr.write(f"idc-autorun-drain: could not read the github board: {e}\n")
        sys.exit(2)
    except (AttributeError, TypeError) as e:
        # The shared reader predates this boundary guard and may raise on a successful-but-wrong JSON
        # top-level shape. Translate that implementation exception into the drain/oracle's stable
        # invalid-board contract instead of leaking a traceback/exit 1.
        _persist_verdict(root, sid, "board-read-error", 2)
        sys.stderr.write(f"idc-autorun-drain: malformed github board response: {e}\n")
        sys.exit(2)
    issues = []
    for it in items:
        content = it.get("content") or {}
        if content.get("type") != "Issue":
            continue
        item_repository = content.get("repository")
        if not isinstance(item_repository, str) \
                or not re.fullmatch(r"[^/\s]+/[^/\s]+", item_repository):
            _reject_malformed_github_item(
                root, sid, "Issue repository identity is missing or invalid")
        if item_repository != repository:
            continue
        title = content.get("title")
        if not isinstance(title, str) or not title.strip():
            _reject_malformed_github_item(
                root, sid, "local Issue title is missing or invalid")
        number = content.get("number")
        if type(number) is not int or number <= 0:
            _persist_verdict(root, sid, "board-read-error", 2)
            sys.stderr.write(
                "idc-autorun-drain: local github issue has a non-positive/invalid number\n")
            sys.exit(2)
        issues.append({
            "number": number,
            "status": it.get("status"),
            "stage": it.get("stage"),
            "title": title,
        })
    unverified = 0
    for it in issues:
        if not _is_build_candidate(it):
            it["blocked_by"] = []
            continue
        try:
            nums, ok = _blocked_by_numbers(repo, it["number"])
        except idc_gh_board.RateLimitError as e:
            # Dependency reads are part of this SAME state snapshot. A throttle here dominates even
            # if an earlier candidate looked eligible; returning that provisional frontier would hide
            # an incomplete board read and violate the shared resumable exit-3 contract.
            _persist_verdict(root, sid, "rate-limited", 3)
            print(f"drain: rate-limited until {e.reset}")
            sys.exit(3)
        except idc_gh_board.MalformedBoardDataError as e:
            _persist_verdict(root, sid, "board-read-error", 2)
            sys.stderr.write(
                f"idc-autorun-drain: malformed github dependency data for "
                f"#{it['number']}: {e}\n")
            sys.exit(2)
        if not ok:
            unverified += 1
            sys.stderr.write(
                f"idc-autorun-drain: blocked_by lookup failed for #{it['number']} — "
                "excluded this pass (will retry next /loop)\n")
            # Self-block with the candidate's own positive Todo identity. It is guaranteed not Done,
            # excludes only this unverified item, and cannot collide with a durable issue sentinel.
            it["blocked_by"] = [it["number"]]
        else:
            it["blocked_by"] = nums
    return issues, unverified


def _run_wave_close_check(script, extra_argv, token, clean_lines, timeout=30):
    """Run a sibling wave-close checker and CLASSIFY its result — the ONE classifier all three share.

    The three wave-close checks (`idc_acceptance_check.py`, `idc_finish_coherence.py`,
    `idc_live_check.py`) deliberately publish the IDENTICAL exit contract — 0 clean, 1 finding, 2
    indeterminate, with a `<token>: …` verdict line on stdout — so the drain can gate on all three
    through one reader instead of three near-copies that drift. Adding a fourth check should mean
    adding a call here, not another classifier.

    `clean_lines` is the set of stdout lines that count as CLEAN at exit 0. It is a set rather than a
    single string because a check may have more than one honest clean answer: `idc_live_check.py`
    reports `live: not-declared` for a repo that declares no live surface, which is every bit as clean
    as `live: ok` and must never read as an error.

    Returns `(cls, line)` where `line` is the checker's verdict line (or a diagnostic one) and `cls` is
    one of:
      * None  — the check DID NOT RUN (the sibling script is absent). Treated as a clean wave close by
                the caller (the acceptance gate never fires), so a repo without the checker is unchanged.
      * "ok"  — the checker exited 0 AND printed one of `clean_lines`.
      * "gap" — the checker exited 1 AND printed `<token>: gap …` (a real finding).
      * "error" — ANYTHING else: a non-zero exit that is not a clean gap, a subprocess failure, a
                missing/unexpected verdict line, or an exit/line disagreement (e.g. a corrupt tracker
                that exits 2). Classified off BOTH the exit code AND the stdout token so a corrupt input
                lands in "error", never masquerading as a silent "ok" (Stage E3 — load-bearing).
    Best-effort: a runner failure classifies as "error" with a diagnostic line rather than raising, so
    the drain's own verdict + exit-code contract is never broken by the check itself. The caller (main)
    is what maps the classification onto the drain verdict/exit — this function only observes the check.
    """
    checker = os.path.join(os.path.dirname(os.path.abspath(__file__)), script)
    if not os.path.isfile(checker):
        return None, None
    try:
        r = subprocess.run([sys.executable, checker, *extra_argv],
                           capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return "error", f"{token}: error ({e})"
    line = None
    for ln in (r.stdout or "").splitlines():
        if ln.startswith(token + ":"):
            line = ln.strip()
            break
    # Classify off BOTH the exit code and the token — a clean OK is exit 0 + a recognized clean line; a
    # clean GAP is exit 1 + `<token>: gap …`. Anything else (a corrupt input's exit 2 with no line, an
    # exit/line disagreement, an unexpected token) is an ERROR the drain must not swallow as complete.
    if r.returncode == 0 and line in clean_lines:
        return "ok", line
    if r.returncode == 1 and line is not None and line.startswith(f"{token}: gap"):
        return "gap", line
    return "error", line or f"{token}: error (no verdict)"


def _run_wave_close_acceptance(tracker):
    """The wave-close inertness check (`idc_acceptance_check.py`) — a merged-`Done` item that shipped
    INERT (autorun audit Fix B). Contract: exit 0 = `acceptance: ok`, 1 = `acceptance: gap <n…>`,
    2 = error (malformed tracker / corrupt issue / unparseable deferral marker — no line on stdout)."""
    return _run_wave_close_check("idc_acceptance_check.py", ["--tracker", tracker],
                                 "acceptance", ("acceptance: ok",))


def _run_wave_close_coherence(args, root):
    """The wave-close board↔reality check (`idc_finish_coherence.py`) — items whose PR merged and whose
    issue closed while the board still says otherwise (the stale-`In Progress` class).

    This is the check whose ABSENCE let a drain print `drain: complete` over a board advertising seven
    items as in-flight that had already shipped. The detector always existed
    (`idc_git_janitor.board_coherence_verdict`); nothing consulted it on a path that could fail.

    The longer timeout is deliberate: this shells through the janitor, which does a real git scan plus
    two bulk `gh` reads on the github backend. It runs ONLY at wave close (the build lane is drained),
    so the cost is paid once per drain, at the exact moment the drain is about to claim it is done.

    The timeout is a CEILING, not an expectation (a local scan returns in about a second). It is bounded
    on purpose so that the degradation is always safe: a check that times out classifies as "error",
    which the caller maps to the non-terminal `drain: unknown` — retry next `/loop`. The Stop fixpoint
    gate re-runs this same drain with its OWN, strictly LARGER timeout, so this inner ceiling always
    trips first. That ordering is load-bearing: an inner timeout degrades to "allow the stop and retry",
    whereas an outer timeout would raise inside the gate and fail CLOSED — wedging a stop over a slow
    git scan. Keep this value below the gate's."""
    argv = ["--repo", root]
    if args.backend == "github":
        argv += ["--backend", "github", "--owner", args.owner, "--project", str(args.project)]
    else:
        argv += ["--tracker", args.tracker]
    # `not-applicable` is a CLEAN answer, not an error: a governed repo with no git has no branches,
    # PRs or merges, so nothing can have shipped and the board cannot be stale about it. Reading it as
    # an error would pin such a repo at `drain: unknown` forever — never able to honestly complete.
    return _run_wave_close_check("idc_finish_coherence.py", argv, "finish-coherence",
                                 ("finish-coherence: ok", "finish-coherence: not-applicable"),
                                 timeout=COHERENCE_TIMEOUT)


def _run_wave_close_live(root):
    """The wave-close live-surface check (`idc_live_check.py`) — a project-DECLARED deployed surface
    whose evidence is missing or has expired.

    Backend-blind (it reads config + git only) and free for any repo that declares no live surface:
    `live: not-declared` is a recognized CLEAN line, so an undeclared repo can never be gated here."""
    return _run_wave_close_check("idc_live_check.py", ["--repo", root], "live",
                                 ("live: ok", "live: not-declared"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", choices=("filesystem", "github"), default="filesystem",
                    help="tracker backend (default: filesystem)")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem backend)")
    ap.add_argument("--project", help="integer project number (github backend)")
    ap.add_argument("--owner", help="project owner login (github backend)")
    ap.add_argument("--repo", default=".",
                    help="repo dir to run gh in (github backend; default cwd)")
    ap.add_argument("--session-id", dest="session_id", default=None,
                    help="drain session id for the persisted verdict (v4 Phase 3 Stage E2; "
                         "default: $CLAUDE_CODE_SESSION_ID). Attributes .idc-drain-verdict.json so the "
                         "Stop fixpoint gate gates only THIS session's own stop. Purely additive — never "
                         "changes the drain verdict/exit-code contract.")
    ap.add_argument("--width", action="store_true",
                    help="also print the ready frontier's width (max-useful parallelism); the ready set is the `eligible:` line")
    ap.add_argument("--acceptance", action="store_true",
                    help="at wave close (the build lane is drained), also invoke idc_acceptance_check.py over "
                         "the same tracker and print its `acceptance: <ok|gap …>` line (filesystem backend; the "
                         "github wave-close acceptance runs in idc:idc-build Phase 4 via a materialized tracker). "
                         "Opt-in so DEFAULT output stays byte-identical. Under --acceptance the result GATES a "
                         "would-be-`complete` wave close (Stage E3): a GAP ⇒ `drain: acceptance-gap` exit 4, an "
                         "ERROR/corrupt check ⇒ `drain: unknown` exit 2 (both NON-TERMINAL); ok ⇒ complete exit 0. "
                         "The Phase-0 exit-code set {0,2,3,4} is unchanged (acceptance-gap is a new TOKEN on exit 4).")
    ap.add_argument("--coherence", action="store_true",
                    help="at wave close, also invoke idc_finish_coherence.py (BOTH backends) and GATE a "
                         "would-be-`complete` verdict on it: items whose work shipped (PR merged / issue "
                         "closed as completed) but whose board Status was never advanced ⇒ "
                         "`drain: coherence-gap` exit 4; an indeterminate check ⇒ `drain: unknown` exit 2. "
                         "Opt-in so DEFAULT output stays byte-identical. Closes the merge→board-flip window "
                         "in idc_git_finish.py: without it a board still advertising shipped work reads as a "
                         "clean terminal `complete`.")
    ap.add_argument("--live", action="store_true",
                    help="at wave close, also invoke idc_live_check.py (backend-blind) and GATE a "
                         "would-be-`complete` verdict on it: a project-DECLARED live surface with missing or "
                         "expired evidence ⇒ `drain: live-gap` exit 4; an indeterminate check ⇒ "
                         "`drain: unknown` exit 2. A repo that declares no live surface reports "
                         "`live: not-declared` and is never gated, so this flag is free to pass anywhere.")
    args = ap.parse_args()

    # Resolve the persisted-verdict target ONCE (Stage E2): the session id (explicit flag or the env
    # the orchestrator exports) and the workspace root the Stop gate reads. Purely additive.
    sid = args.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID") or None
    root = _workspace_root(args)

    unverified = 0
    if args.backend == "github":
        if not args.project or not args.owner:
            sys.stderr.write("idc-autorun-drain: --project and --owner are required for the github backend\n")
            sys.exit(2)
        issues, unverified = load_github(args.owner, args.project, os.path.abspath(args.repo),
                                         root=root, sid=sid)
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
    # WAVE-CLOSE ACCEPTANCE (opt-in, v4 Phase 3 Stage B): when the build lane is drained (`not
    # eligible`) — the point the drain loop finishes a wave — invoke the EXISTING sibling
    # idc_acceptance_check.py over the same tracker so a merged-"Done" issue can never ship INERT
    # (autorun audit Fix B). Deterministic + reuses that script (never reimplements inertness); prints
    # ONE extra `acceptance: <ok|gap …>` line, and NEVER touches the fixpoint math or the drain
    # verdict/exit-code contract (Phase 0). Filesystem only — the github lane materializes a tracker in
    # idc:idc-build Phase 4; the drain holds no TRACKER.md for a github board. The orchestrator reads
    # the line and files a recirculation on a gap (its job — the drain never recirculates).
    accept_cls = None
    if args.acceptance and not eligible and args.tracker:
        accept_cls, accept_line = _run_wave_close_acceptance(args.tracker)
        if accept_line:
            print(accept_line)
    # WAVE-CLOSE COHERENCE + LIVE (opt-in, both backends). Same shape and same moment as the acceptance
    # check above — the build lane is drained, so this is the point the drain decides whether the pipe is
    # genuinely finished. They answer the two questions the drain could not previously ask:
    #   * coherence — "does the board still claim work that already shipped?" The drain's own eligibility
    #     math counts only `Todo`, so an item stranded at `In Progress` by a session that died between the
    #     merge and the board flip is INVISIBLE to it — it printed `complete` and the Stop gate then
    #     cleared the orchestrator marker, laundering a lying board into a clean bill of health.
    #   * live — "was the deployed surface this project declared actually driven, on the code that is
    #     running now?" Every other gate verifies code; none of them can tell a green build from a
    #     working product.
    # Both print ONE extra verdict line and never touch the fixpoint math; the gate is applied below.
    coherence_cls = live_cls = None
    if args.coherence and not eligible:
        coherence_cls, coherence_line = _run_wave_close_coherence(args, root)
        if coherence_line:
            print(coherence_line)
    if args.live and not eligible:
        live_cls, live_line = _run_wave_close_live(root)
        if live_line:
            print(live_line)
    # AGGREGATE fail-closed verdict (the github blind-drain guard): NO eligible work remains AND at
    # least one build candidate's blocked_by lookup was unverifiable — so we CANNOT prove the build
    # lane is drained. Emitting `drain: complete` here would recreate the silent false-clean this whole
    # fix repudiates (autorun treats `complete` as TERMINAL and stops). Report `drain: unknown` + exit 2
    # so autorun retries next `/loop` instead, and skip the width line (the frontier is unknowable). (A
    # NON-EMPTY eligible set is safe to `continue` on — the unverifiable candidates simply retry next
    # loop. The filesystem path never sets `unverified`, so its verdict is unchanged.) This precedes the
    # recirc-pending branch: an unprovable build lane is a stronger signal than a non-empty inbox.
    if not eligible and unverified:
        _persist_verdict(root, sid, "unknown", 2)
        print("drain: unknown")
        sys.exit(2)
    # WHOLE-PIPE fixpoint (the second/third conjuncts): the build lane is drained (nothing eligible)
    # but the Recirculation inbox or the admitted-but-unplanned consideration lane still owes upstream
    # work — the pipe is NOT at a fixpoint. A DISTINCT non-zero verdict (`drain: recirc-pending` + exit
    # 4) so autorun does not treat this as terminal `complete`: the next /loop drains the inbox
    # (/idc:recirculate) / plans the consideration, then re-checks. Both backends share it (the counts
    # come from the same already-loaded `issues`). Skip the width line — the build frontier is empty here.
    if not eligible and (recirc_inbox or unplanned):
        _persist_verdict(root, sid, "recirc-pending", 4)
        print("drain: recirc-pending")
        sys.exit(4)
    # WAVE-CLOSE ACCEPTANCE GATE (v4 Phase 3 Stage E3): the build lane is drained and no stronger
    # non-terminal signal (unverified/recirc-pending) fired — so the drain WOULD print terminal
    # `drain: complete`. But if the wave-close acceptance check (opt-in, filesystem) could not prove the
    # wave clean, `complete` would let a corrupt/inert close masquerade as a terminal fixpoint and stop
    # autorun. GATE the would-be-`complete` verdict on the acceptance classification:
    #   * ERROR (checker errored / exited 2 / unrunnable / no verdict — e.g. a corrupt tracker) ⇒ we
    #     CANNOT prove the wave clean → `drain: unknown` + exit 2 (same non-terminal signal as the github
    #     blind-drain guard above; autorun retries next /loop).
    #   * GAP (a merged-Done item is inert) ⇒ `drain: acceptance-gap` + exit 4 (a NON-TERMINAL verdict on
    #     the EXISTING exit-4 code — a new TOKEN, not a new exit code; the `acceptance: gap …` line above
    #     names the inert items so the orchestrator recirculates them, per autorun.md).
    #   * ok / None (clean, or --acceptance not passed / not filesystem / checker absent) ⇒ falls through
    #     to `drain: complete` exit 0, byte-identical to before. Persist the new verdicts (Stage E2) so
    #     the github Stop gate reads them, mirroring the branches above.
    if not eligible and accept_cls == "error":
        _persist_verdict(root, sid, "unknown", 2)
        print("drain: unknown")
        sys.exit(2)
    if not eligible and accept_cls == "gap":
        _persist_verdict(root, sid, "acceptance-gap", 4)
        print("drain: acceptance-gap")
        sys.exit(4)
    # COHERENCE + LIVE GATES — identical shape to the acceptance gate above, applied after it so the
    # existing verdicts keep exact precedence and a run passing neither new flag is byte-for-byte
    # unchanged. Each maps ERROR ⇒ non-terminal `drain: unknown` exit 2 (we cannot PROVE the pipe clean,
    # so autorun retries next /loop) and a FINDING ⇒ a distinct verdict TOKEN on the EXISTING
    # non-terminal exit 4. Exit 4 is what the Stop fixpoint gate already refuses a stop on, so wiring
    # these two here is what makes them enforceable — no new hook, no new exit code, and the Phase-0
    # exit-code set {0,2,3,4} is preserved.
    #
    # COHERENCE IS CHECKED BEFORE LIVE on purpose: a stale board is a statement about what is TRUE, and
    # a live-evidence gap is a statement about what was PROVEN. Reporting "your board is lying" before
    # "your app is unverified" puts the orchestrator on the fact it must fix first — and repairing the
    # board is mechanical, while re-driving a live surface is not.
    if not eligible and coherence_cls == "error":
        _persist_verdict(root, sid, "unknown", 2)
        print("drain: unknown")
        sys.exit(2)
    if not eligible and coherence_cls == "gap":
        _persist_verdict(root, sid, "coherence-gap", 4)
        print("drain: coherence-gap")
        sys.exit(4)
    if not eligible and live_cls == "error":
        _persist_verdict(root, sid, "unknown", 2)
        print("drain: unknown")
        sys.exit(2)
    if not eligible and live_cls == "gap":
        _persist_verdict(root, sid, "live-gap", 4)
        print("drain: live-gap")
        sys.exit(4)
    _final = "continue" if eligible else "complete"
    _persist_verdict(root, sid, _final, 0)
    print("drain: " + _final)
    if args.width:
        # The ready frontier IS the `eligible:` set already printed above; width is its size = the
        # unblocked eligible antichain that can be staffed in parallel right now (the sous-chef
        # count; Wave is never consulted). No `ready-frontier:` line — it would byte-duplicate
        # `eligible:`; consumers read the ready set from `eligible:` and the count from here.
        print("width: " + str(len(eligible)))


if __name__ == "__main__":
    main()
