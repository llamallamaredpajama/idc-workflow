#!/usr/bin/env python3
"""idc_teammate_idle_synth.py — the DRAIN-LOOP phantom-idle-teammate synthesizer
(v4 Phase 3 Stage E4, plan §3.2 drop H — "Phantom-idle teammate (impl-235)").

WHY THIS EXISTS (the hole the drain is blind to). An implementer teammate can go IDLE without
reporting: its board item sits `Stage=Buildable ∧ Status=In Progress` (claimed), but the teammate
will never advance it. The drain LOOP is blind to this state — `idc_autorun_drain.py`'s
`compute_eligible` counts only `Todo`, the recirculation inbox counts only
`Recirculation/Consideration ∧ Todo`, and the acceptance check only audits merged-`Done` — so the
wave closes `drain: complete` and autorun STOPS with the item silently STRANDED. The lead
historically recovered by HAND: inspect the worktree/branch/PR, discover the work was actually
committed (finish it) or actually absent (reclaim it). This script makes that inspection a
DETERMINISTIC step the drain loop runs at the top of every pass — exactly like Stage E1's
`idc_recirc_reconcile.py` (`TeammateIdle` is NOT a real Claude Code hook event; the transport is the
drain loop, the only path that survives a hard kill because no hook fires).

WHAT IT DOES. For every `Buildable ∧ In Progress` board item (board = ground truth), it SYNTHESIZES
the teammate's real state from LOCAL git evidence (never an LLM, never a per-item `gh pr view` loop)
and stamps ONE idempotent breadcrumb comment per (item, class):
  * synthesized-complete — a linked branch's work has LANDED in base, proven by POSITIVE evidence
    (never ancestry alone, which cannot tell landed work from a stale empty branch — reviewer P1a):
    an already-in-base tip whose commit DECLARES this item (Stage D's Issue/Item trailer), OR a
    per-commit patch-equivalent squash/rebase, OR an aggregate-patch-equivalent multi-commit squash
    (codex P2a). The work LANDED but the board never advanced. Stamp {branch, tip sha, evidence} +
    print `teammate-idle: <n> synthesized-complete branch <b>` so the ORCHESTRATOR finishes via the
    SANCTIONED CLOSE-ONLY finisher (`idc_git_finish.py --close-only` — the plain finisher hard-fails
    at `gh pr merge` on an already-merged PR). This script NEVER closes/moves the item — code surfaces
    evidence; the orchestrator owns the transition through the engine.
  * in-flight-abandoned — a linked branch exists with commits ahead of base but unmerged: stamp a
    resume-checkpoint {branch, ahead-count, tip sha} + print `teammate-idle: <n> in-flight branch
    <b> ahead <k>` so a resumed implementer picks it up instead of restarting.
  * stalled-no-evidence — NO linked branch/commits discoverable: stamp "claimed but no discoverable
    work — reclaim or re-dispatch" + print `teammate-idle: <n> no-evidence`.

BRANCH DISCOVERY reuses Stage D's linkage convention — the item number IN the branch name
(`_BRANCH_NUM_RE` from `scripts/hooks/idc_post_commit_sync.py`, IMPORTED not re-invented). It scans
`git for-each-ref refs/heads` (+ `refs/remotes/origin` best-effort) in the governed repo; a worktree
checkout of the branch counts through its ref. Multiple matching branches → the strongest class wins
(complete ≻ in-flight), SAFE-bias over-annotate.

IDEMPOTENCE LATCH = a ledger taint per item (Stage A `idc_ledger.py`), kind `idle_synth`, key=item,
carrying the synthesis CLASS in its fields — mirroring E1's `recirc_checkpoint:<ticket>` latch. Stamp
ONCE per (item, class); a CHANGED class (in-flight → synthesized-complete) RE-STAMPS (the new
evidence matters — the latch is class-keyed, not a dumb once-ever); an item leaving In-Progress CLEARS
its taint (cross-session, board-proven — E1's clear branch is the pattern). Every In-Progress item's
synthesis is REPORTED (printed) every pass; only the COMMENT is latched, so a healthy in-flight
teammate accrues exactly ONE breadcrumb, not spam.

SAFE-BIAS — OVER-ANNOTATE, NEVER UNDER-ANNOTATE. A stranded item is the loss; a breadcrumb is
recoverable. So when the board CANNOT be read (`in_progress is None` — a missing/corrupt/locked
tracker) the synthesis reports `teammate-idle: unknown`, clears NOTHING (a stale taint survives
rather than being wiped) and stamps nothing — a read failure must NEVER look like "no In-Progress
items" (that false-empty is the exact drop-H strand).

FAIL MODE (P4). This is an ACTION script inside the drain LOOP, not a pre-action gate: it FAILS SOFT
(a top-level guard warns + exits 0 on any internal error; usage errors exit 2) and NEVER crashes the
loop. It is REPO-GATED (an instant no-op outside an IDC-governed repo) and honors
`IDC_HOOKS_OBSERVE_ONLY=1` as a PURE DRY RUN — it warns what it WOULD stamp/clear and mutates NEITHER
the board NOR the ledger (crucially it does NOT pre-write the taint, which would latch the item and
rob a later enforce pass of its breadcrumb).

THE DRAIN SCRIPT ITSELF IS UNTOUCHED — `idc_autorun_drain.py` output stays byte-identical; the synth
is a SIBLING the loop invokes. Its own stdout contract: `teammate-idle:` lines only.

GITHUB is best-effort (not hermetically tested here — E5's sandbox e2e covers github surfaces); the
filesystem backend is the hermetic, load-bearing path. The board read is ONE `fetch_items` per pass
inside the DRAIN LOOP (NOT on the stop path — the Stop gate stays 0-GraphQL); NO per-item PR lookup.

REUSE (import, never re-implement). From `scripts/hooks/idc_recirc_closeout_gate.py`: `_read_backend`,
`_fs_query`, `_fs_comment`, `_read_project_number`, `_gh_owner`, `TRACKER_FS`. From
`scripts/hooks/idc_post_commit_sync.py`: `_BRANCH_NUM_RE`. From `scripts/hooks/idc_ledger.py`: the
taint API. From `scripts/hooks/idc_hook_lib.py`: is_governed_repo / observe_only / warn.

Invocation (mirrors idc_recirc_reconcile.py):
    python3 idc_teammate_idle_synth.py --repo <cwd> [--backend filesystem|github]
        [--tracker <TRACKER.md>] [--base <branch>] [--session-id <sid>]
Output (stable, greppable — one line per In-Progress item, plus an `unknown` on an unreadable board):
    teammate-idle: <n> synthesized-complete branch <b>
    teammate-idle: <n> in-flight branch <b> ahead <k>
    teammate-idle: <n> no-evidence
    teammate-idle: unknown            (unreadable board — never a false "none")
    teammate-idle: ungoverned         (not an IDC-governed repo)
Exit 0 = ran (synthesized / no-op / unknown — all fail-soft); 2 = usage error.

RESIDUALS / LIMITATIONS (documented, by design):
  * Staging merge train: with a two-stage promotion pipeline (idc-build.md e2e layering), a branch
    squash-merged to a STAGING base but not yet promoted to `main` reads as in-flight, not
    synthesized-complete — arguably honest (the pipe isn't done until promotion) and the steer is
    recoverable (a resumed implementer finds the landed work). If the repo's merge train should count
    staging as landed, the orchestrator passes `--base <staging>` so containment measures against it.
"""
import argparse
import os
import re
import subprocess
import sys

# Stage C's gate, Stage D's sync, the ledger + hook lib all live in scripts/hooks/ — put that dir on
# sys.path so we IMPORT the already-factored helpers rather than re-deriving them (this file is in
# scripts/, exactly like the sibling idc_recirc_reconcile.py).
_HOOKS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks")
sys.path.insert(0, _HOOKS)
import idc_hook_lib as H            # noqa: E402  (is_governed_repo / observe_only / warn)
import idc_ledger                   # noqa: E402  (the taint API — import, never edit)
import idc_recirc_closeout_gate as G  # noqa: E402  (reuse the factored fs query/comment + gh helpers)
import idc_post_commit_sync as PCS  # noqa: E402  (_ISSUE_TRAILER_RE — Stage D's trusted commit trailer)

# THE CREDENTIAL SCRUB DOOR — see `idc_credential_shapes.scrub`. Every read of a CHILD PROCESS's
# stderr in this module passes through it AT THE READ, and `tests/smoke/phase11-honesty-repro.sh` R28
# is the census that keeps that true across every module in scripts/.
#
# THE IMPORT IS TOLERANT BECAUSE SEVERAL MODULES HERE RUN AS LONE RELOCATED COPIES. The smoke and
# governance suites copy a single script to a temp directory and execute it there to prove a deleted
# guard was the one doing the work (`phase1-pipe-safety` F, `governance/external-intake-completeness`,
# `phase4-completion-honesty` F) — a hard sibling import makes those copies die on ImportError. The
# fallback FAILS CLOSED: with no table to scrub with, a child's stderr is WITHHELD, never passed
# through. This block is byte-identical everywhere it appears and R28 asserts that, so no copy of it
# can drift into a pass-through.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import idc_credential_shapes as CS  # noqa: E402
except ImportError:                                      # a lone relocated copy — fail closed
    class CS:                                            # noqa: N801 — stand-in for the shared table
        scrub = staticmethod(
            lambda text: text and "[child output withheld — the credential table is not importable]")

IDLE_TAINT = "idle_synth"                 # (kind, key=item) latch; the class rides in the taint fields
IDLE_MARKER = "[idc-idle-synth]"          # grep anchor on the stamped comment

# BRANCH → ITEM resolution (reviewer P2-1 + P2-A). The claude adapter names build branches
# `worktree-build-<n>` / `impl-<n>` / `<n>-slug` (skills/idc-adapter-claude/SKILL.md — `impl-235` IS
# the phantom-idle incident drop H exists for). Stage D's strict `PCS._BRANCH_NUM_RE` (number LEADS a
# path segment) matches `<n>-slug`/`issue-<n>` but MISSES the adapter's `worktree-build-<n>` shape, so
# discovery needs to also recognize that shape. But the resolved number STEERS a close / re-dispatch,
# so — unlike a pure breadcrumb — Stage D's "a wrong guess is worse than saying nothing" applies: link
# ONLY when UNAMBIGUOUS. A branch carrying MULTIPLE standalone numbers (`phase-3/worktree-build-42`,
# date prefixes) must not steer some unrelated item, so it links via a SHAPE if one matches, else only
# when there is exactly ONE number, else NOTHING (warned, never a silent drop).
_STRICT_ITEM_RE = PCS._BRANCH_NUM_RE   # Stage D strict: the number LEADS a path segment
_ADAPTER_ITEM_RE = re.compile(r"(?:^|/)(?:worktree-)?(?:build|impl|unit|fix|issue)-(\d+)$")  # adapter shape
_ITEM_TOKEN_RE = re.compile(r"(?:^|[-_/])(\d+)(?=$|[-_/])")   # any standalone numeric token


def _standalone_numbers(ref):
    """Every standalone numeric token in a ref (deduped, sorted) — used only to REPORT what an
    ambiguous ref contained; linkage itself goes through _resolve_ref_item."""
    return sorted({int(m.group(1)) for m in _ITEM_TOKEN_RE.finditer(ref or "")})


def _resolve_ref_item(ref):
    """(item_number_or_None, all_standalone_numbers) for a branch ref — UNAMBIGUOUS linkage only
    (P2-A). Order: (1) the ADAPTER shape `(worktree-)?(build|impl|unit|fix|issue)-<n>` (END-anchored,
    the authoritative IDC unit-branch convention), else (2) the strict Stage D leading-segment regex,
    else (3) exactly ONE standalone numeric token; else None (ambiguous / none).

    ADAPTER IS CONSULTED FIRST (round-8 micro-fix): consulting the strict leading-segment regex first
    let a date/parent PREFIX win via the `or` short-circuit — `2026-07/worktree-build-42` resolved 2026
    (the date), a WRONG-item stamp, defeating the round-5 guard. The end-anchored adapter unit shape is
    authoritative, so when both match it wins over the strict prefix (the real unit is `worktree-build-42`
    → 42; close-only ownership then refuses any --issue that is not 42, so no wrong close)."""
    ref = ref or ""
    nums = _standalone_numbers(ref)
    m = _ADAPTER_ITEM_RE.search(ref) or _STRICT_ITEM_RE.search(ref)
    if m:
        return int(m.group(1)), nums
    if len(nums) == 1:
        return nums[0], nums
    return None, nums

# The three synthesis classes (stored verbatim in the taint's `cls` field — the class-keyed latch).
CLS_COMPLETE = "synthesized-complete"
CLS_INFLIGHT = "in-flight-abandoned"
CLS_NO_EVIDENCE = "stalled-no-evidence"
# The AMBIGUOUS-ANCESTOR breadcrumb (reviewer P1a): a branch tip already reachable from base with NO
# positive contribution evidence — landed OR a stale empty branch, undeterminable → no-evidence.
_AMBIGUOUS_ANCESTOR_EV = ("branch tip already in base — landed or stale (undeterminable); check base "
                          "history / merged PRs for this item's work before reclaiming")
# Aggregate squash-detection cap (codex P2a): a multi-commit branch squashed into ONE base commit
# defeats per-commit `git cherry`, so we compare the branch's AGGREGATE patch-id against base commits
# since the merge-base — bounded to the newest _AGG_CAP of them so a long base history stays cheap.
_AGG_CAP = 200


def _plugin_root():
    """The plugin root — the parent of scripts/ (this file is scripts/idc_teammate_idle_synth.py).
    Used to locate the sibling tracker/board helpers the reused functions shell out to."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


# ── local git evidence (best-effort; a git hiccup is UNDETERMINABLE linkage, never a crash) ────────
# Reuse Stage D's byte-identical helper (one git subprocess → stripped stdout, or None on ANY failure
# — spawn error / non-zero / timeout). Local git only, never a board read (NIT-4: no second copy).
_run_git = PCS._run_git


def _git_is_ancestor(cwd, commit, base):
    """True iff <commit> is an ancestor of <base> (i.e. its work has fully LANDED in base). Uses the
    exit code of `git merge-base --is-ancestor` (0 = ancestor, 1 = not, other = error → False)."""
    try:
        r = subprocess.run(["git", "-C", cwd, "merge-base", "--is-ancestor", commit, base],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


def _base_candidates(cwd, base):
    """The ORDERED, deduped LIST of base committishes to measure a branch against (reviewer P2-2). A
    single local ref is not enough: if the operator fetched WITHOUT fast-forwarding local `main`, landed
    work sits in `origin/main` while local `main` lags — measuring only against the stale local ref
    reports a false in-flight on merged work. So we consider the resolved local base PLUS its
    remote-tracking counterpart (`origin/<base>`) PLUS the remote's default branch
    (`git symbolic-ref refs/remotes/origin/HEAD`), and the usual main/master fallbacks — every one that
    resolves, deduped in priority order. A branch is `complete` vs ANY candidate (its work provably
    landed on SOME authoritative base — safe for BOTH the fetch-no-ff and the unpushed-local-merge
    shapes). An EMPTY list (nothing resolves) is the SAFE-bias fail-safe: every item → no-evidence."""
    raw = [base, "origin/" + base if base else None, "main", "master"]
    sym = _run_git(cwd, "symbolic-ref", "refs/remotes/origin/HEAD")  # e.g. refs/remotes/origin/main
    if sym and sym.startswith("refs/remotes/"):
        raw.append(sym[len("refs/remotes/"):])                       # → origin/main
    raw += ["origin/main", "origin/master"]
    seen, out = set(), []
    for cand in raw:
        if not cand or cand in seen:
            continue
        seen.add(cand)
        if _run_git(cwd, "rev-parse", "--verify", "--quiet", cand + "^{commit}") is not None:
            out.append(cand)
    return out


def _branches_by_item(cwd):
    """Map {item_number: [(refname, tip_sha), ...]} for every local/remote branch whose name carries a
    board-item number per Stage D's `_BRANCH_NUM_RE`. Scans `refs/heads` (+ `refs/remotes/origin`
    best-effort — a worktree checkout counts through its ref). A ref with no item number, and the
    `origin/HEAD` symbolic pointer, are skipped. Returns {} on a git failure (no evidence, never a
    crash)."""
    out = _run_git(cwd, "for-each-ref", "--format=%(refname:short) %(objectname)",
                   "refs/heads", "refs/remotes/origin")
    by_item = {}
    if not out:
        return by_item
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2:
            continue
        ref, tip = parts
        if ref.endswith("/HEAD"):   # origin/HEAD symbolic ref — not a real branch
            continue
        # UNAMBIGUOUS linkage only (P2-A): the resolved number steers a close/re-dispatch, so a ref
        # with multiple numbers and no supported shape links NOTHING and is warned — never silently
        # steers an unrelated item (the item still surfaces as no-evidence if it has no other branch).
        num, nums = _resolve_ref_item(ref)
        if num is None:
            if len(nums) > 1:
                H.warn(f"teammate-idle: skipped ambiguous ref {ref} (numbers "
                       f"{', '.join(str(n) for n in nums)} — no supported shape, >1 candidate)")
            continue
        by_item.setdefault(num, []).append((ref, tip))
    return by_item


def _worktrees(cwd):
    """[(path, branch_or_None)] for every registered worktree (`git worktree list --porcelain`), or []
    on a git failure. A detached worktree has branch None. Used to recover an idle implementer's
    UNCOMMITTED work (P2-2 — the drop-H incident's most common shape: teammates go idle WITHOUT
    committing)."""
    out = _run_git(cwd, "worktree", "list", "--porcelain")
    res, path, branch = [], None, None
    if not out:
        return res
    for line in out.splitlines():
        if line.startswith("worktree "):
            if path is not None:
                res.append((path, branch))
            path, branch = line[len("worktree "):].strip(), None
        elif line.startswith("branch "):
            ref = line[len("branch "):].strip()
            branch = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
    if path is not None:
        res.append((path, branch))
    return res


def _worktree_dirty(path):
    """True iff `git -C <path> status --porcelain` reports uncommitted/untracked changes. Best-effort:
    an unreadable/missing worktree (git fails → None) reads as NOT dirty — degrading to the current
    no-evidence behavior, never a crash (P2-2)."""
    return bool(_run_git(path, "status", "--porcelain"))


def _dirty_linked_worktree(cwd, item, worktrees):
    """(branch_label, path) of the FIRST worktree LINKED to <item> whose working tree is DIRTY, or None.
    A worktree links to the item if its BRANCH resolves to the item (the checked-out zero-commit branch)
    OR its PATH basename does (a detached / oddly-branched worktree) — the SAME unambiguous resolution
    used for refs. This recovers uncommitted local work instead of reclaiming it (P2-2)."""
    for path, branch in worktrees:
        linked = _resolve_ref_item(branch)[0] if branch else None
        if linked is None:
            linked = _resolve_ref_item(os.path.basename(path.rstrip("/")))[0]
        if linked != item:
            continue
        if _worktree_dirty(path):
            return (branch or os.path.basename(path.rstrip("/"))), path
    return None


def _git_ahead(cwd, base, ref):
    """Commits in <ref> not reachable from <base> (`git rev-list --count base..ref`), or 0 on failure."""
    n = _run_git(cwd, "rev-list", "--count", base + ".." + ref)
    return int(n) if (n and n.isdigit()) else 0


def _tip_declares_item(cwd, tip, item):
    """True iff the tip commit's OWN message carries Stage D's trusted Issue/Item trailer
    (`PCS._ISSUE_TRAILER_RE`) naming THIS item — a deliberate declaration that this commit is the
    item's work. This is the POSITIVE contribution evidence the ancestry fast-path requires (reviewer
    P1a): ancestry alone cannot tell ff/merge-landed work from a stale empty branch the base merely
    advanced past (both tips are ancestors), so an ancestor is `complete` ONLY with this declaration."""
    msg = _run_git(cwd, "log", "-1", "--format=%B", tip) or ""
    m = PCS._ISSUE_TRAILER_RE.search(msg)
    return bool(m) and int(m.group(1)) == item


def _patch_id(cwd, diff_argv):
    """The stable patch-id of a diff (`git <diff_argv>` piped into `git patch-id --stable`), or None.
    Best-effort: any spawn/exit failure, or an EMPTY diff (patch-id emits nothing), returns None."""
    try:
        d = subprocess.run(["git", "-C", cwd, *diff_argv], capture_output=True, text=True, timeout=15)
        if d.returncode != 0 or not d.stdout:
            return None
        p = subprocess.run(["git", "-C", cwd, "patch-id", "--stable"],
                           input=d.stdout, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    toks = p.stdout.split()
    return toks[0] if toks else None


def _aggregate_squash_landed(cwd, ref, base):
    """True iff the branch's AGGREGATE diff (all its commits since the merge-base, as ONE patch) is
    patch-equivalent to a single commit already in base — the multi-commit-squash case per-commit
    `git cherry` cannot see (codex P2a): N branch commits collapse into ONE base commit whose combined
    patch-id matches none of the N individual patch-ids. Compares the branch's aggregate patch-id
    against each base commit since the merge-base, bounded to the newest _AGG_CAP. All local git."""
    mb = _run_git(cwd, "merge-base", base, ref)
    if not mb:
        return False
    branch_pid = _patch_id(cwd, ["diff", mb, ref])
    if not branch_pid:
        return False
    log = _run_git(cwd, "log", "--format=%H", mb + ".." + base)
    if not log:
        return False
    for i, commit in enumerate(log.splitlines()):
        if i >= _AGG_CAP:
            break
        if _patch_id(cwd, ["diff-tree", "-p", commit]) == branch_pid:
            return True
    return False


def _classify_branch(cwd, item, ref, tip, base):
    """One matching branch's state vs base. Returns (cls, ahead, evidence) with cls ∈
    {CLS_COMPLETE, CLS_INFLIGHT, None} (None = no distinct work on this ref).

    SQUASH-MERGE BLINDNESS is the crux (codex P1). IDC's default finisher squash-merges
    (`gh pr merge --squash --delete-branch`), so LANDED work is NOT an ancestor of base — a merge-base
    ancestry test alone would call an already-merged branch `in-flight` (→ autorun re-dispatches work
    that already shipped). So after the cheap ancestry fast-path (a fast-forward / merge-commit landing)
    we fall through to `git cherry <base> <ref>`, which marks each ahead-commit by PATCH equivalence:
    `-` = an equivalent commit already exists in base (it LANDED — squash/rebase/cherry-pick), `+` =
    genuinely unmerged. ALL `-` ⇒ synthesized-complete (patch-equivalent); ANY `+` ⇒ still in-flight,
    ahead = the count of genuinely-unmerged commits (a partial-landing is unfinished). An undeterminable
    cherry with commits ahead degrades to in-flight — the SAFE direction (never a false no-evidence /
    complete that would strand or prematurely close).

    ANCESTRY NEEDS POSITIVE EVIDENCE (reviewer P1a — the zero-commit guard's real root cause). A commit
    is its own ancestor, and ancestry ALONE cannot tell ff/merge-commit-landed work from a STALE EMPTY
    branch the base merely advanced past — BOTH tips are reachable from base (`tip == base` is only the
    special case where the base has not advanced). Calling either `complete` would route a
    board-advancing finish on un-landed / empty work (the ONE forbidden direction). So the ancestry
    fast-path returns `complete` ONLY when the tip commit carries a POSITIVE contribution declaration:
    Stage D's trusted Issue/Item trailer naming THIS item (`_tip_declares_item`). Any other
    already-in-base tip is AMBIGUOUS → no-evidence with a check-history breadcrumb (the LLM judges),
    NEVER a false complete."""
    ahead = _git_ahead(cwd, base, ref)
    if _git_is_ancestor(cwd, tip, base):
        if _tip_declares_item(cwd, tip, item):
            return CLS_COMPLETE, 0, "branch tip merged into base; tip commit declares this item (Issue/Item trailer)"
        base_sha = _run_git(cwd, "rev-parse", "--verify", base + "^{commit}")
        if base_sha is not None and tip != base_sha:
            # tip already IN base but no declaration — landed-without-a-trailer OR a stale empty branch
            # the base advanced past. Undeterminable ⇒ no-evidence + check-history (never a false close).
            return CLS_NO_EVIDENCE, 0, _AMBIGUOUS_ANCESTOR_EV
        return None, 0, ""   # tip == base: a created-but-never-committed claim (nothing distinct)
    cherry = _run_git(cwd, "cherry", base, ref)   # per-commit patch-equivalence vs base
    if cherry is None:
        # `git cherry` could not run — undeterminable. If the ref is ahead at all, bias to in-flight
        # (never a false no-evidence, never a false complete).
        return (CLS_INFLIGHT, ahead, "unmerged (patch-equivalence undeterminable)") if ahead > 0 else (None, 0, "")
    lines = [ln for ln in cherry.splitlines() if ln.strip()]
    unmerged = [ln for ln in lines if ln.startswith("+")]   # `+` = no patch-equivalent in base
    if lines and not unmerged:
        # every ahead-commit is patch-equivalent to a commit already in base → squash/rebase LANDED.
        return CLS_COMPLETE, 0, "squash/patch-equivalent (all ahead-commits already landed in base)"
    if unmerged:
        # Per-commit cherry says unmerged — but a MULTI-commit branch squashed into ONE base commit
        # looks exactly like this (codex P2a). Try the aggregate patch-id before concluding in-flight.
        if _aggregate_squash_landed(cwd, ref, base):
            return CLS_COMPLETE, 0, "squash-landed (aggregate patch-equivalent to a base commit)"
        return CLS_INFLIGHT, len(unmerged), f"unmerged ({len(unmerged)} commit(s) not yet in base)"
    if ahead > 0:  # ahead but `git cherry` listed nothing — shouldn't happen; bias in-flight (safe)
        return CLS_INFLIGHT, ahead, "unmerged (patch-equivalence indeterminate)"
    return None, 0, ""


def _classify_branch_multi(cwd, item, ref, tip, bases):
    """One branch's state against the base CANDIDATE LIST (reviewer P2-2). `complete` vs ANY candidate
    wins (its work provably landed on SOME authoritative base — covers fetch-no-ff AND unpushed-local-
    merge). Otherwise in-flight with the FEWEST unmerged commits across candidates (the truest resume
    picture — a candidate that already has more of the work reports fewer remaining commits).
    no-evidence only when it is no-evidence/None vs every candidate. Returns (cls, ahead, evidence)."""
    best_inflight = None   # (ahead, evidence) — fewest unmerged across candidate bases
    ambiguous_ev = None
    for base in bases:
        cls, ahead, ev = _classify_branch(cwd, item, ref, tip, base)
        if cls == CLS_COMPLETE:
            return CLS_COMPLETE, 0, ev   # landed vs SOME authoritative base — strongest, short-circuit
        if cls == CLS_INFLIGHT and (best_inflight is None or ahead < best_inflight[0]):
            best_inflight = (ahead, ev)
        elif cls == CLS_NO_EVIDENCE and ambiguous_ev is None:
            ambiguous_ev = ev
    if best_inflight is not None:
        return CLS_INFLIGHT, best_inflight[0], best_inflight[1]
    if ambiguous_ev is not None:
        return CLS_NO_EVIDENCE, 0, ambiguous_ev
    return None, 0, ""


def _synthesize(cwd, item, bases, by_item, worktrees):
    """The teammate's real state for one In-Progress item, from LOCAL git evidence. Returns
    (cls, branch, tip, ahead, evidence). EVERY matching ref is evaluated (no short-circuit — codex P2):
      * in-flight-abandoned — whenever ANY linked ref is genuinely ahead of every base candidate (the
        richest resume point wins). This DOMINATES a stale complete sibling: a merged local ref must
        NEVER mask a still-ahead ref of the same item (a stale local-merged branch alongside an advanced
        origin/* ref, or two same-item branches).
      * synthesized-complete — ONLY when ≥1 ref is complete AND NO ref is in-flight (nothing unmerged
        remains anywhere).
      * in-flight-abandoned (uncommitted) — no committed evidence, but a LINKED worktree has UNCOMMITTED
        changes (P2-2 — the drop-H incident's most common shape: teammates go idle WITHOUT committing);
        resume it, never reclaim.
      * stalled-no-evidence — no committed evidence and no dirty linked worktree (carrying any ambiguous
        already-in-base evidence — P1a)."""
    branches = by_item.get(item, [])
    best_inflight = None    # (ahead, ref, tip, evidence) — most unmerged across refs (richest resume)
    best_complete = None    # (ref, tip, evidence) — a landed ref, used ONLY if nothing is in-flight
    ambiguous_ev = None     # an already-in-base tip with no contribution declaration (P1a)
    if branches and bases:
        for ref, tip in branches:
            cls, ahead, ev = _classify_branch_multi(cwd, item, ref, tip, bases)
            if cls == CLS_INFLIGHT and (best_inflight is None or ahead > best_inflight[0]):
                best_inflight = (ahead, ref, tip, ev)
            elif cls == CLS_COMPLETE and best_complete is None:
                best_complete = (ref, tip, ev)
            elif cls == CLS_NO_EVIDENCE and ambiguous_ev is None:
                ambiguous_ev = ev
        # Committed in-flight DOMINATES: any genuinely-ahead ref means unmerged work still exists —
        # never a false complete that would steer a close while work remains.
        if best_inflight is not None:
            return CLS_INFLIGHT, best_inflight[1], best_inflight[2], best_inflight[0], best_inflight[3]
    # UNCOMMITTED work DOMINATES complete too (codex round-8 P2): a landed branch whose worktree still
    # has uncommitted edits is NOT done — resume it, never clean up over recoverable local changes. So
    # the dirty-worktree probe runs BEFORE the complete return, not only on the no-evidence path.
    dirty = _dirty_linked_worktree(cwd, item, worktrees)
    if dirty is not None:
        label, path = dirty
        return (CLS_INFLIGHT, label, None, 0,
                f"uncommitted changes in worktree {path} (resume, do not reclaim)")
    # Nothing unmerged remains anywhere → a landed ref, if any, is genuinely complete.
    if best_complete is not None:
        return CLS_COMPLETE, best_complete[0], best_complete[1], 0, best_complete[2]
    # If an ambiguous already-in-base tip was seen, surface its check-history evidence (the LLM judges).
    return CLS_NO_EVIDENCE, None, None, 0, (ambiguous_ev or "")


# ── the breadcrumb comment (one per (item, class); the orchestrator owns the transition) ──────────
def _synth_body(item, cls, branch, tip, ahead, evidence=""):
    """The idempotent breadcrumb comment body for one synthesis class. It NEVER claims the item was
    closed/moved — it surfaces evidence + names the SANCTIONED remediation the orchestrator performs."""
    br = branch or "unknown"
    sha = (tip or "unknown")[:12]
    ev = f" [{evidence}]" if evidence else ""
    if cls == CLS_COMPLETE:
        # The work is ALREADY MERGED, so the normal finisher (which runs `gh pr merge`) would hard-fail
        # at the merge step — the remediation is the IDEMPOTENT CLOSE-ONLY recovery (skip the merge,
        # verify the merged state as the receipt, then the normal cleanup + tracker-close tail).
        return (f"{IDLE_MARKER} SYNTHESIZED-COMPLETE — item #{item} is claimed "
                f"(Stage=Buildable ∧ Status=In Progress) but its work has LANDED: branch {br} "
                f"(tip {sha}) is merged into the base branch{ev}, yet the board was never advanced — a "
                f"phantom-idle teammate. The work is ALREADY merged, so recover with the CLOSE-ONLY "
                f"finisher — `idc_git_finish.py --close-only --pr <pr> --issue {item}` (it SKIPS the "
                f"merge, verifies the merged state as the receipt, then runs the normal cleanup + "
                f"tracker-close tail); the plain finisher would hard-fail at `gh pr merge`. This "
                f"breadcrumb never closes the item — the orchestrator owns the transition.")
    if cls == CLS_INFLIGHT:
        return (f"{IDLE_MARKER} IN-FLIGHT / RESUME — item #{item} is claimed but its teammate went "
                f"idle mid-work: branch {br} (tip {sha}) has {ahead} unmerged commit(s) ahead of "
                f"base{ev}. Resume from this branch (do NOT restart) — a re-dispatched implementer "
                f"picks up exactly here.")
    # NO local branch/commit signal — but a SQUASH-MERGE that also DELETED its branch leaves NO local
    # ref, so this can be an already-landed item whose branch is gone. Before reclaiming, the
    # orchestrator must CHECK for a merged PR / a base-history commit referencing #<item> (code stays
    # deterministic on the local signal; the LLM judges this ambiguous, no-local-signal case).
    return (f"{IDLE_MARKER} STALLED / NO EVIDENCE — item #{item} is claimed "
            f"(Stage=Buildable ∧ Status=In Progress) but NO landed/in-flight branch is discoverable "
            f"LOCALLY{ev} — either its teammate went idle with no recoverable work, OR the work was "
            f"squash-merged and its branch deleted (no local ref survives), OR a stale claim branch is "
            f"already in base. BEFORE reclaiming: check for a merged PR / a base-history commit "
            f"referencing #{item} — if found, recover CLOSE-ONLY (`idc_git_finish.py --close-only`); "
            f"otherwise RECLAIM or RE-DISPATCH the item.")


def _print_line(item, cls, branch, ahead):
    """The stable, greppable per-item stdout the orchestrator reads (one line per In-Progress item,
    EVERY pass — the readout is not latched, only the comment is)."""
    if cls == CLS_COMPLETE:
        print(f"teammate-idle: {item} synthesized-complete branch {branch}")
    elif cls == CLS_INFLIGHT:
        print(f"teammate-idle: {item} in-flight branch {branch} ahead {ahead}")
    else:
        print(f"teammate-idle: {item} no-evidence")


def _existing_classes(cwd):
    """Map {item_number: class} for every current `idle_synth` taint, read UNSCOPED (`read_taints`):
    the drain spans sessions — a taint a DEAD prior pass left is exactly what this pass reconciles, so
    the current session id must not filter it out (E1's cross-session pattern). A non-numeric key is
    ignored. The class rides in the taint's `fields.cls`."""
    out = {}
    for t in idc_ledger.read_taints(cwd):
        if t.get("kind") != IDLE_TAINT:
            continue
        try:
            item = int(t.get("key"))
        except (TypeError, ValueError):
            continue
        out[item] = (t.get("fields") or {}).get("cls")
    return out


def _fs_comment_ok(trk, tracker, cwd, num, body):
    """Stamp a breadcrumb via the sanctioned filesystem tracker `comment` op, returning True ONLY on a
    CONFIRMED write (rc 0), False otherwise (spawn error / non-zero — a transient failure). Mirrors
    G._fs_comment's invocation but SURFACES the status G swallows: the caller must not latch the taint
    on a failed write, or the durable breadcrumb never lands and cross-session recovery breaks (P2-B)."""
    try:
        r = subprocess.run([sys.executable, trk, "--tracker", tracker, "comment",
                            "--num", str(num), "--body", body],
                           cwd=cwd, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError) as e:
        H.warn(f"teammate-idle: could not stamp breadcrumb on #{num}: {e}")
        return False
    if r.returncode != 0:
        H.warn(f"teammate-idle: breadcrumb on #{num} failed (rc={r.returncode}): "
               f"{CS.scrub(r.stderr or '').strip()[:200]}")
        return False
    return True


def _read_in_progress(cwd, backend, plugin_root):
    """(in_progress, commenter) — the Buildable ∧ In Progress board items + a sanctioned commenter.
    The commenter returns True on a CONFIRMED write, False on failure (P2-B — the caller latches the
    taint only on True).
    `in_progress` is **None** on an unreadable board (the SAFE-bias sentinel — NOT `[]`, which would
    look like a genuinely empty board and wipe every taint). Filesystem is hermetic (reuses G._fs_query
    / G._fs_comment); github is best-effort (reuses G._read_project_number / G._gh_owner + idc_gh_board)."""
    if backend == "github":
        return _gh_in_progress_and_commenter(cwd, plugin_root)
    trk = os.path.join(plugin_root or "", "scripts", G.TRACKER_FS)
    tracker = os.path.join(cwd, "TRACKER.md")
    if not (os.path.isfile(trk) and os.path.isfile(tracker)):
        H.warn(f"teammate-idle: tracker helper/file missing (trk={os.path.isfile(trk)}, "
               f"TRACKER.md={os.path.isfile(tracker)}) — board undeterminable; preserving taints")
        return None, None
    in_progress = G._fs_query(trk, tracker, "Buildable", "In Progress")  # None on a failed/corrupt read
    commenter = lambda n, body: _fs_comment_ok(trk, tracker, cwd, n, body)  # noqa: E731 — returns bool
    return in_progress, commenter


def _gh_in_progress_and_commenter(cwd, plugin_root):
    """(in_progress, commenter) for the github backend via the SANCTIONED helpers (idc_gh_board
    fetch_items to enumerate, add_comment — `gh issue comment`, NOT a raw board mutation — to stamp).
    Best-effort: any failure returns (None, None) so the caller reports `unknown` and preserves taints.
    Reuses the Stage C gate's owner/project readers (import, never re-derive)."""
    scripts = os.path.join(plugin_root or "", "scripts")
    if os.path.isdir(scripts):
        sys.path.insert(0, scripts)
    try:
        import idc_gh_board  # noqa: E402 — lazy: only the github path pays this import
    except ImportError:
        return None, None
    project_number = G._read_project_number(cwd)
    owner = G._gh_owner(cwd)
    if not (owner and project_number):
        H.warn(f"teammate-idle: github owner/project undeterminable (owner={owner!r}, "
               f"project={project_number!r}) — board undeterminable; preserving taints")
        return None, None
    try:
        items = idc_gh_board.fetch_items(owner, project_number, cwd)
    except Exception as e:  # noqa: BLE001 — a board read failure must not break the drain (SAFE-bias)
        H.warn(f"teammate-idle: github board read failed, cannot enumerate In-Progress items: {e}")
        return None, None
    in_progress = []
    for it in items:
        if (it.get("stage") or "Buildable") != "Buildable":
            continue
        if it.get("status") != "In Progress":
            continue
        num = (it.get("content") or {}).get("number")
        if num is None:  # a draft item has no issue to comment on
            continue
        in_progress.append(int(num))

    def commenter(n, body):
        # Returns True on a CONFIRMED write, False on failure (a gh rate-limit / transient error), so
        # the caller latches the taint only on success (P2-B — a failed write must be retried next pass).
        try:
            idc_gh_board.add_comment(n, body, cwd)
            return True
        except Exception as e:  # noqa: BLE001 — best-effort stamp
            H.warn(f"teammate-idle: could not stamp breadcrumb on #{n} (github): {e}")
            return False

    return in_progress, commenter


def synthesize(cwd, backend, base, session_id):
    """The deterministic synthesis. Returns (verdict, synthesized, cleared, results) where
      * verdict ∈ {ungoverned, unknown, complete (no In-Progress items), synthesized};
      * synthesized = items that got a NEW/RE-STAMPED breadcrumb this pass;
      * cleared = items whose taint was cleared (left In-Progress);
      * results = [(item, cls, branch, tip, ahead, evidence), ...] for EVERY In-Progress item."""
    plugin_root = _plugin_root()

    if not H.is_governed_repo(cwd):
        return "ungoverned", [], [], None

    in_progress, commenter = _read_in_progress(cwd, backend, plugin_root)
    if in_progress is None:
        # UNKNOWN board — could not be read. We CANNOT prove there are no In-Progress items, so we must
        # NOT clear any taint (clearing on an unproven-empty board is the exact drop-H strand) and must
        # NOT stamp (we don't know which items). Preserve everything, report unknown, warn.
        H.warn("teammate-idle: could not determine the board (tracker/board unreadable) — preserving "
               "existing idle_synth taints, stamping nothing (state NOT wiped)")
        return "unknown", [], [], None

    bases = _base_candidates(cwd, base)   # local base + origin/<base> + origin/HEAD (P2-2)
    by_item = _branches_by_item(cwd)
    worktrees = _worktrees(cwd)           # for the uncommitted-work recovery probe (P2-2)
    existing = _existing_classes(cwd)   # {item: class} — the class-keyed idempotence latch
    observe = H.observe_only()
    ip_set = set(in_progress)

    # Synthesize every In-Progress item (the readout + the stamp candidates).
    results = []
    for item in in_progress:
        cls, branch, tip, ahead, evidence = _synthesize(cwd, item, bases, by_item, worktrees)
        results.append((item, cls, branch, tip, ahead, evidence))

    # CLEAR — a taint whose item has LEFT the In-Progress set (finished/reclaimed/re-dispatched). The
    # obligation is satisfied; the breadcrumb is stale. Item-keyed + cross-session, board-proven.
    clear_candidates = sorted(k for k in existing if k not in ip_set)
    # STAMP candidates — a NEW item (no taint) OR a CHANGED class (the latch is class-keyed, so an
    # in-flight → synthesized-complete transition re-stamps the new evidence). Same (item, class) as an
    # existing taint is SKIPPED (the idempotence latch — no duplicate comment).
    to_stamp = [r for r in results if existing.get(r[0]) != r[1]]

    if observe:
        # OBSERVE-ONLY is a pure dry run: NO ledger mutation and NO board comment — only a report of
        # what WOULD happen. Critically it must NOT write the taint either, or a later enforce pass
        # would find the item already-latched and NEVER write its breadcrumb (E1's observe doctrine).
        if clear_candidates:
            H.warn(f"OBSERVE-ONLY: would clear stale idle_synth taints {clear_candidates} "
                   "(their items left In-Progress) — ledger untouched")
        if to_stamp:
            H.warn(f"OBSERVE-ONLY: would stamp idle-synth breadcrumbs for "
                   f"{[(r[0], r[1]) for r in to_stamp]} (comment + taint) — "
                   "board + ledger untouched")
        return ("complete" if not in_progress else "synthesized"), [], [], results

    for k in clear_candidates:
        idc_ledger.clear_taint(cwd, IDLE_TAINT, key=k)

    synthesized = []
    for item, cls, branch, tip, ahead, evidence in to_stamp:
        # Latch the taint ONLY after a CONFIRMED breadcrumb write (P2-B). If the comment write FAILS
        # (transient gh rate-limit / fs error), setting the taint anyway would make the next pass skip
        # the commenter — the durable breadcrumb never lands and cross-session recovery breaks. On
        # failure: warn, leave the item un-latched, and it is re-tried on the next pass.
        if not commenter(item, _synth_body(item, cls, branch, tip, ahead, evidence)):
            H.warn(f"teammate-idle: breadcrumb write for #{item} FAILED — NOT latching the taint "
                   "(will retry next pass)")
            continue
        # The taint is written by this script (never the LLM), keyed by item, carrying the CLASS so a
        # later class-change re-stamps; it clears above once the item leaves In-Progress.
        idc_ledger.set_taint(cwd, IDLE_TAINT, key=item, session_id=session_id,
                             cls=cls, branch=(branch or ""), tip=(tip or ""),
                             ahead=str(ahead), via="drain-idle-synth")
        synthesized.append(item)

    verdict = "complete" if not in_progress else "synthesized"
    return verdict, synthesized, clear_candidates, results


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Drain-loop phantom-idle-teammate synthesis from git evidence (v4 Phase 3 E4)")
    ap.add_argument("--repo", default=".", help="governed workspace root (default: cwd)")
    ap.add_argument("--backend", choices=("filesystem", "github"), default=None,
                    help="tracker backend (default: auto-detect from docs/workflow/tracker-config.yaml, "
                         "else filesystem) — mirrors E1; a github repo needs no flag")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem); its dir is used as the repo root")
    ap.add_argument("--base", default="main",
                    help="base branch to measure merged/ahead against (default: main, then master)")
    ap.add_argument("--session-id", dest="session_id", default=None,
                    help="session id for taint attribution (default: $CLAUDE_CODE_SESSION_ID)")
    args = ap.parse_args(argv)

    # The filesystem readers key off <cwd>/TRACKER.md, so a --tracker anchors the repo root at its dir.
    if args.tracker:
        cwd = os.path.dirname(os.path.abspath(args.tracker)) or "."
    else:
        cwd = os.path.abspath(args.repo)
    sid = args.session_id or os.environ.get("CLAUDE_CODE_SESSION_ID") or None
    # Auto-detect the backend from the governed repo's config when not forced (E1's / Stage C's
    # _read_backend) — a github repo whose caller forgot --backend github must NOT be read as an absent
    # filesystem tracker (a permanent `teammate-idle: unknown`, protection off).
    backend = args.backend or (G._read_backend(cwd) or "filesystem")

    verdict, synthesized, cleared, results = synthesize(cwd, backend, args.base, sid)
    if verdict == "ungoverned":
        print("teammate-idle: ungoverned")
        return 0
    if results is None:  # unknown board — NEVER a false "none"
        print("teammate-idle: unknown")
        return 0
    for item, cls, branch, tip, ahead, evidence in results:
        _print_line(item, cls, branch, ahead)
    # A summary footer (greppable, does not collide with the per-item lines).
    print("teammate-idle-summary: verdict=" + verdict
          + " synthesized=" + " ".join(str(i) for i in synthesized)
          + " cleared=" + " ".join(str(i) for i in cleared))
    return 0


if __name__ == "__main__":
    # FAIL-SOFT top-level guard: a synthesis error must NEVER crash the drain loop (this is an action
    # step, not a pre-action gate). Warn + exit 0 on any internal error; argparse usage errors exit 2.
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as _e:  # noqa: BLE001 — infra bug, never a reason to break the drain loop
        H.warn(f"teammate-idle synth errored, failing soft (drain loop continues): {_e}")
        sys.exit(0)
