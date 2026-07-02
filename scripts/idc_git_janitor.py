#!/usr/bin/env python3
"""idc_git_janitor.py — the deterministic board↔git reconciler (`WORKFLOW.md §A`).

One read-only-by-default scanner that, from a SINGLE board read + the merged-PR list, compares board
state against git reality (worktrees, local+remote branches, board↔issue↔PR coherence, attribution)
and classifies every finding into four verdict tiers:

  * SAFE-FIX     — IDC-attributable AND merged AND clean. The only tier `--apply-safe` touches:
                   remove a clean merged worktree, delete a merged branch (local + remote), close a
                   Done-but-open issue, set Status=Done on an issue whose work merged. Deterministic,
                   reversible-by-recreation, no judgment.
  * REPORT-ONLY  — non-IDC artifacts (Codex / Antigravity / team-execute / claude / recovery debris).
                   ALWAYS listed, NEVER touched — the janitor does not clean tooling it did not create.
  * RISKY        — dirty worktree, unmerged branch, or ambiguous attribution. Listed with a suggested
                   action; only ever applied one-by-one on explicit operator confirmation (never here).
  * COHERENT     — no findings.

Attribution is by branch/worktree NAMING only (deterministic, no LLM): IDC = `idc-*`, `build*`,
`plan/*`, `recirculate/*`, `worktree-*`; anything else is non-IDC → REPORT-ONLY, full stop.

"Merged" is backend-appropriate (a GitHub squash-merge does NOT preserve ancestry, so ancestry alone
would miss the exact RC2 stragglers this tool exists to reap):
  * github     — a branch is merged iff its name is in the merged-PR head-ref set (`gh pr list
                 --state merged`), OR (belt) its tip is an ancestor of the default branch.
  * filesystem — a branch is merged iff its tip is an ancestor of the default branch (there are no
                 PRs). Real merges preserve ancestry, so this is exact for a non-GitHub repo.

Fail-closed, mirroring `idc_autorun_drain.py`:
  exit 0  clean (COHERENT — zero findings, and no dimension was indeterminate).
  exit 1  findings present (any tier — "debris present → non-zero", the e2e post-condition contract).
  exit 2  ground truth could not be established (not a git repo, unresolved default branch, an
          unreadable board), OR the result would otherwise be clean but a dimension was indeterminate
          (a degraded secondary read could be masking findings) — never a hollow clean.

The scanner is the netting layer the fix package hangs on and is reused verbatim as the sandbox e2e
post-condition gate (a clean repo exits 0; debris exits non-zero with a machine-readable report).
`--json` emits the structured report for programmatic consumers.

Provenance coherence ("Buildable with no `idc-provenance` marker") is intentionally NOT scanned here:
it needs per-issue body reads (an O(N) API cost this cost-aware tool avoids) and already has a
dedicated detective — the SessionEnd recirc sweep (`idc_recirc_sweep.py`) and doctor Row 9b. The
janitor reconciles git↔board state; the sweep owns Plan-output provenance integrity.

Backends:
  filesystem — `--tracker <TRACKER.md>` (board is the tracker state block; issue "state" IS Status).
  github     — `--backend github --owner <o> --project <n> [--repo <dir>]` (board via the shared
               paginating reader `idc_gh_board`; issue OPEN/CLOSED + merged PRs via `gh`).
  git-only   — omit all board args: scan only git (worktrees + branches); board coherence is reported
               as "not scanned" (explicit, never a silent skip). A valid pure-git post-condition gate.

Usage:
  idc_git_janitor.py [--repo DIR] [--tracker T | --backend github --owner O --project N] [--apply-safe] [--json]
"""
import argparse
import json
import os
import re
import subprocess
import sys

# --- attribution -----------------------------------------------------------------------------------
# IDC-attributable branch/worktree naming (the design's exact list). Anchored at the START, and `build`
# REQUIRES a `-`/`/` separator (`build-*`/`build/*`) so a foreign name that merely starts with the
# letters "build" — buildbot, buildkite, builder-x — is NOT misread as IDC. (`worktree-build-*` is still
# covered by the `worktree-` alternative.)
IDC_NAME_RE = re.compile(r"^(idc-|build[-/]|plan/|recirculate/|worktree-)")
# Known non-IDC tooling, labelled for a readable REPORT-ONLY line (the tier is binary IDC/not — this
# only annotates WHICH foreign tool, so the operator can route it; an unmatched foreign name is "unknown").
FOREIGN_TOOLS = (
    ("codex", "codex"),
    ("antigravity", "antigravity"),
    ("team-execute", "team-execute"),
    ("te-", "team-execute"),
    ("recovery", "recovery"),
    ("claude", "claude"),
)
# A merged IDC build branch names its issue: worktree-build-7 / build-7 / build/7 -> issue #7.
BUILD_ISSUE_RE = re.compile(r"build[-/]?(\d+)\b")

SAFE_FIX, REPORT_ONLY, RISKY, COHERENT = "SAFE-FIX", "REPORT-ONLY", "RISKY", "COHERENT"


def is_idc(name):
    return bool(IDC_NAME_RE.match(name or ""))


def foreign_label(name):
    low = (name or "").lower()
    for token, label in FOREIGN_TOOLS:
        if token in low:
            return label
    return "unknown"


# --- git plumbing ----------------------------------------------------------------------------------
def git(args, repo, check=False):
    """Run `git <args>` in `repo`. Returns (stdout, returncode). Never raises on a git error; a
    missing-git / OSError surfaces as returncode 127 so callers fail-closed uniformly."""
    try:
        p = subprocess.run(["git", "-C", repo] + args, capture_output=True, text=True)
    except (OSError, ValueError):
        return "", 127
    if check and p.returncode != 0:
        return "", p.returncode
    return p.stdout, p.returncode


def is_git_repo(repo):
    _, rc = git(["rev-parse", "--git-dir"], repo)
    return rc == 0


def default_branch(repo):
    """Resolve the default branch name, or None (→ exit 2). origin/HEAD first (shared truth), then a
    local main/master, then the primary worktree's current branch."""
    out, rc = git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo)
    if rc == 0 and out.strip():
        return out.strip().split("/", 1)[-1]
    for cand in ("main", "master"):
        _, rc = git(["rev-parse", "--verify", "--quiet", "refs/heads/" + cand], repo)
        if rc == 0:
            return cand
    out, rc = git(["rev-parse", "--abbrev-ref", "HEAD"], repo)
    if rc == 0 and out.strip() and out.strip() != "HEAD":
        return out.strip()
    return None


def _ref_exists(repo, ref):
    _, rc = git(["rev-parse", "--verify", "--quiet", ref], repo)
    return rc == 0


def is_ancestor(repo, ref, base):
    """True iff `ref`'s tip is an ancestor of `base` (i.e. a real merge landed it). merge-base
    --is-ancestor exits 0 = yes, 1 = no; any other code (bad ref) reads as not-an-ancestor."""
    _, rc = git(["merge-base", "--is-ancestor", ref, base], repo)
    return rc == 0


def tip_sha(repo, ref):
    """The full commit SHA `ref` points at, or "" if the ref does not resolve."""
    out, rc = git(["rev-parse", "--verify", "--quiet", ref], repo)
    return out.strip() if rc == 0 else ""


def pr_signal_ok(pr_oid, tip):
    """Is the merged-PR name signal SAFE to treat as merged? ONLY when the branch's tip STILL equals
    the PR's merged head commit (`pr_oid`). A reused name pointing at DIVERGENT commits — or an
    unresolvable oid/tip — is NOT a safe merge signal (else --apply-safe would force-delete live work);
    the caller then falls back to ancestry, and a divergent tip fails that too → the branch is RISKY."""
    return bool(pr_oid and tip and pr_oid == tip)


def list_worktrees(repo):
    """Parse `git worktree list --porcelain` into ordered blocks. The FIRST block is always the main
    worktree (git guarantees this regardless of cwd); callers skip it."""
    out, rc = git(["worktree", "list", "--porcelain"], repo)
    if rc != 0:
        return None
    trees, cur = [], {}
    for line in out.splitlines():
        if not line.strip():
            if cur:
                trees.append(cur)
                cur = {}
            continue
        if line.startswith("worktree "):
            if cur:
                trees.append(cur)
            cur = {"path": line[len("worktree "):]}
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].replace("refs/heads/", "", 1)
        elif line.strip() == "detached":
            cur["detached"] = True
    if cur:
        trees.append(cur)
    return trees


def worktree_dirty(path):
    """True iff the worktree has uncommitted changes (tracked OR untracked). A non-zero git status
    (path gone, not a worktree) reads as dirty — fail-closed: never auto-remove what we can't prove clean."""
    out, rc = git(["status", "--porcelain"], path)
    if rc != 0:
        return True
    return bool(out.strip())


def local_branches(repo):
    out, rc = git(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], repo)
    if rc != 0:
        return []
    return [b for b in out.splitlines() if b.strip()]


def remote_branches(repo):
    """origin/* short names (the trailing part after 'origin/'), skipping origin/HEAD.

    NOTE these are the clone's LOCAL remote-tracking refs, which go STALE on an un-pruned clone: a
    branch deleted on the server still shows here until `git fetch --prune`. Callers that act on remote
    branches must intersect this with `ls_remote_heads` (the authoritative server state) so a phantom
    tracking ref is never reported as live nor targeted by `git push --delete`."""
    out, rc = git(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin/"], repo)
    if rc != 0:
        return []
    names = []
    for ref in out.splitlines():
        ref = ref.strip()
        if not ref or ref == "origin/HEAD" or ref.endswith("/HEAD"):
            continue
        if ref.startswith("origin/"):
            names.append(ref[len("origin/"):])
    return names


def ls_remote_heads(repo):
    """The set of branch short names that ACTUALLY exist on `origin` right now — authoritative and
    READ-ONLY (`git ls-remote` queries the server, never mutating a local ref, so it is safe in the
    default report mode). ONE network call, not per-branch. Returns None if the remote can't be queried
    (offline / no `origin`), so the caller fail-closes the remote-branch dimension rather than trust
    possibly-stale local tracking refs."""
    out, rc = git(["ls-remote", "--heads", "origin"], repo)
    if rc != 0:
        return None
    heads = set()
    for line in out.splitlines():
        parts = line.split("\trefs/heads/", 1)   # each line: "<sha>\trefs/heads/<name>"
        if len(parts) == 2 and parts[1].strip():
            heads.add(parts[1].strip())
    return heads


# --- merged-PR + issue-state maps (github) ---------------------------------------------------------
def gh_json(args, repo):
    """Run `gh <args>` in repo, parse stdout as JSON. Returns (value, ok)."""
    try:
        p = subprocess.run(["gh"] + args, cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError):
        return None, False
    if p.returncode != 0:
        return None, False
    try:
        return json.loads(p.stdout or "null"), True
    except json.JSONDecodeError:
        return None, False


# `gh <list> --limit N` is a hard CEILING, not a "fetch all" — a read that returns exactly N items may
# be TRUNCATED. So a result AT the cap makes that dimension possibly-partial → indeterminate (fail-closed).
PR_LIST_LIMIT = 1000
ISSUE_LIST_LIMIT = 2000


def read_at_cap(n, limit):
    """True iff a list read returned >= its --limit — so it may be truncated (partial) and the caller
    must treat the derived maps as indeterminate rather than silently trust a possibly-partial board."""
    return n >= limit


def board_coherence_verdict(status, state, reason, closed_by_pr):
    """PURE github board↔issue coherence decision (unit-tested). Returns (tier, op, detail) or None.

    A Done-stamping fix requires the issue to be genuinely COMPLETED — a merged PR closed it, OR it was
    closed with stateReason COMPLETED. An issue closed as NOT_PLANNED (abandoned/won't-do) must NEVER be
    stamped Status=Done — that is a RISKY manual reconcile, not a SAFE-FIX. `state`/`reason` are
    upper-cased ("OPEN"/"CLOSED", "COMPLETED"/"NOT_PLANNED"/""); `closed_by_pr` = a merged PR closed it."""
    if status == "Done" and state == "OPEN":
        return (SAFE_FIX, "close-issue", "Status=Done but the issue is still OPEN")
    if status != "Done":
        if closed_by_pr:
            return (SAFE_FIX, "set-done", f"Status={status or 'unset'} but a merged PR closed it")
        if state == "CLOSED":
            if reason == "COMPLETED":
                return (SAFE_FIX, "set-done", f"Status={status or 'unset'} but the issue is CLOSED as completed")
            return (RISKY, "reconcile",
                    f"Status={status or 'unset'} but the issue is CLOSED as "
                    f"{reason.lower() or 'unspecified'} (not completed)")
    return None


def github_merge_maps(repo):
    """Build the github merge/issue maps in TWO bulk reads. Returns a dict:
      merged_refs   {branch name of a merged PR}
      merged_oids   {head ref name → the PR's merged head commit SHA} (the tip-match guard)
      closed_issues {issue# a merged PR closes}
      issue_state   {issue# → OPEN/CLOSED}
      issue_reason  {issue# → COMPLETED/NOT_PLANNED/…} (the Done-stamping gate)
      ok            both reads succeeded
      capped        a read hit its --limit ceiling (possibly partial)
      indeterminate a read failed OR was capped → the coherence/github-merged dimensions can't be fully
                    established this pass (the caller refuses a clean verdict — never a hollow clean)."""
    prs, ok1 = gh_json(
        ["pr", "list", "--state", "merged", "--limit", str(PR_LIST_LIMIT),
         "--json", "number,headRefName,headRefOid,closingIssuesReferences"], repo)
    issues, ok2 = gh_json(
        ["issue", "list", "--state", "all", "--limit", str(ISSUE_LIST_LIMIT),
         "--json", "number,state,stateReason"], repo)
    merged_refs, merged_oids, closed_issues, states, reasons = set(), {}, set(), {}, {}
    capped = False
    if ok1 and isinstance(prs, list):
        capped = capped or read_at_cap(len(prs), PR_LIST_LIMIT)
        for pr in prs:
            ref = pr.get("headRefName")
            if ref:
                merged_refs.add(ref)
                oid = pr.get("headRefOid")
                if oid:
                    merged_oids[ref] = oid
            for c in (pr.get("closingIssuesReferences") or []):
                n = c.get("number")
                if isinstance(n, int):
                    closed_issues.add(n)
    if ok2 and isinstance(issues, list):
        capped = capped or read_at_cap(len(issues), ISSUE_LIST_LIMIT)
        for it in issues:
            n = it.get("number")
            if isinstance(n, int):
                states[n] = (it.get("state") or "").upper()
                reasons[n] = (it.get("stateReason") or "").upper()
    ok = ok1 and ok2
    return {"merged_refs": merged_refs, "merged_oids": merged_oids, "closed_issues": closed_issues,
            "issue_state": states, "issue_reason": reasons, "ok": ok, "capped": capped,
            "indeterminate": (not ok) or capped}


# --- board loaders ---------------------------------------------------------------------------------
def load_board_github(owner, project, repo):
    """All issue-backed board items via the paginating reader. Returns list of
    {number,status,stage,title,item_id}. Exits 2 on an unreadable board (fail-closed, no hollow clean)."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_gh_board  # noqa: E402 — github-only dependency, imported lazily
    try:
        items = idc_gh_board.fetch_items(owner, project, repo)
    except idc_gh_board.BoardReadError as e:
        sys.stderr.write(f"idc-git-janitor: could not read the github board: {e}\n")
        sys.exit(2)
    except Exception as e:  # noqa: BLE001 — ANY unexpected board-read failure fail-CLOSES to exit 2
        # An uncaught exception would exit 1 (== our "findings" code) with a traceback, masquerading a
        # crash as a clean-ish result. Fail-closed: exit 2, never a hollow clean or a false "findings".
        sys.stderr.write(f"idc-git-janitor: unexpected error reading the github board: {e}\n")
        sys.exit(2)
    board = []
    for it in items:
        content = it.get("content") or {}
        number = content.get("number")
        if number is None:
            continue
        board.append({
            "number": number,
            "status": it.get("status"),
            "stage": it.get("stage"),
            "title": content.get("title") or "",
            "item_id": it.get("id"),
        })
    return board


def load_board_filesystem(path):
    """Read the filesystem TRACKER.md state block → list of {number,status,stage,title}.

    Reuses `idc_autorun_drain.load_filesystem` — the ONE owner of the state-block fence + the
    fail-closed corruption contract (a missing/corrupt tracker or a missing `issues` key ≠ an empty
    board → exit 2; an explicit `issues: []` is a legitimate empty board). Not re-copied here, so the
    drainer and the janitor can never disagree about what a valid board is. (On corruption the exit-2
    diagnostic carries the drainer's `idc-autorun-drain:` prefix; the exit code is what matters.)"""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_autorun_drain  # noqa: E402 — sibling helper, imported lazily (the established pattern)
    issues = idc_autorun_drain.load_filesystem(path)  # exits 2 itself on any corruption
    return [{"number": it["number"], "status": it.get("status"),
             "stage": it.get("stage"), "title": it.get("title") or ""} for it in issues]


# --- the scan --------------------------------------------------------------------------------------
def finding(tier, dim, name, detail, action="", **extra):
    f = {"tier": tier, "dim": dim, "name": name, "detail": detail, "action": action}
    f.update(extra)
    return f


def scan(ctx):
    """Return (findings, indeterminate). Pure over ctx (git + board already loaded). indeterminate is
    True when a dimension could not be fully established (a degraded github secondary read) — the
    caller refuses a clean verdict in that case (fail-closed)."""
    repo, backend = ctx["repo"], ctx["backend"]
    default = ctx["default"]
    findings = []
    indeterminate = ctx.get("board_indeterminate", False)
    locals_ = local_branches(repo)          # each git-shell-out done ONCE per scan; reused below
    remotes_ = remote_branches(repo)
    # Truthfulness on an un-pruned clone: local origin/* tracking refs go stale, so intersect them with
    # the AUTHORITATIVE server state (one read-only `git ls-remote`) before classifying/acting. Without
    # this, a branch already deleted on the server shows as a phantom remote finding, and --apply-safe's
    # `git push --delete` then fails on it. If the remote can't be queried (offline), we cannot verify
    # remote truth → drop the remote-branch dimension for this pass AND mark indeterminate (never report
    # an unverifiable phantom as live debris, and never a hollow clean).
    if remotes_:
        live = ls_remote_heads(repo)
        if live is not None:
            remotes_ = [b for b in remotes_ if b in live]
        else:
            sys.stderr.write("idc-git-janitor: `git ls-remote` failed — remote-branch state "
                             "unverifiable this pass; skipping that dimension (indeterminate)\n")
            remotes_ = []
            indeterminate = True

    # merged-branch predicate, backend-appropriate. Memoized on (short, remote): the branch scans and
    # the filesystem coherence loop query the same branches, so a cache collapses the repeats to zero
    # extra git calls. `origin_default_ref` is the origin/<default> ref (or None) resolved ONCE in
    # build_ctx — hoisted out so its `git rev-parse --verify` doesn't re-run per call.
    merged_refs = ctx.get("merged_refs", set())
    merged_oids = ctx.get("merged_oids", {})
    origin_default_ref = ctx.get("origin_default_ref")
    _merged_cache = {}

    def branch_merged(short, remote=False):
        key = (short, remote)
        if key in _merged_cache:
            return _merged_cache[key]
        ref = ("refs/remotes/origin/" + short) if remote else ("refs/heads/" + short)
        # The merged-PR head-ref set is the authoritative github signal — but ONLY if the branch's tip
        # STILL equals the PR's merged head commit (pr_signal_ok). A name reused for divergent new work
        # must NOT read as merged (else --apply-safe force-deletes live commits); it falls through to
        # ancestry, which a divergent tip fails → RISKY, never force-deleted. Off github merged_refs is
        # empty, so this is skipped and we go straight to ancestry.
        if short in merged_refs and pr_signal_ok(merged_oids.get(short), tip_sha(repo, ref)):
            res = (True, "pr")
        else:
            anc = is_ancestor(repo, ref, default)               # local default contains it?
            if not anc and origin_default_ref:
                anc = is_ancestor(repo, ref, origin_default_ref)  # …or origin/default does
            res = (anc, "ancestry") if anc else (False, "")
        _merged_cache[key] = res
        return res

    # ---- worktrees (skip the main worktree, always block 0) ----
    trees = ctx["worktrees"]
    wt_branches = set()          # every branch checked out in a linked worktree
    wt_safefix_branches = set()  # subset whose worktree is SAFE-FIX (clean + merged) → branch deletable
    for wt in trees[1:] if trees else []:
        path = wt.get("path", "")
        name = wt.get("branch") or os.path.basename(path)
        if wt.get("branch"):
            wt_branches.add(wt["branch"])
        if not is_idc(name):
            findings.append(finding(
                REPORT_ONLY, "worktree", path,
                f"non-IDC ({foreign_label(name)}) worktree on '{name}'", "never auto-fixed (foreign)"))
            continue
        if worktree_dirty(path):
            findings.append(finding(
                RISKY, "worktree", path,
                f"IDC worktree '{name}' has uncommitted changes",
                "commit or discard the changes, then re-run"))
            continue
        merged, _via = branch_merged(name) if wt.get("branch") else (False, "")
        if not merged:
            findings.append(finding(
                RISKY, "worktree", path,
                f"IDC worktree '{name}' is clean but its branch is not merged",
                "review/merge the branch, then re-run"))
            continue
        findings.append(finding(
            SAFE_FIX, "worktree", path,
            f"clean, IDC worktree '{name}' whose branch merged", "remove worktree", branch=name))
        if wt.get("branch"):
            wt_safefix_branches.add(wt["branch"])

    # ---- branches (local + remote — same classification, one helper) ----
    def classify_branch(name, dim, remote):
        if name == default:
            return
        # A LOCAL branch checked out in a worktree that is NOT itself SAFE-FIX cannot be deleted (git
        # refuses a checked-out branch) — that worktree's finding is the actionable one, so don't
        # double-report. A SAFE-FIX worktree's branch IS reported (apply-safe removes the worktree
        # first, then the branch becomes deletable). Remote names never match a worktree branch.
        if not remote and name in wt_branches and name not in wt_safefix_branches:
            return
        kind = "remote" if remote else "local"
        if not is_idc(name):
            detail = f"non-IDC ({foreign_label(name)}) {kind} branch"
            findings.append(finding(REPORT_ONLY, dim, name,
                                    detail + (f" origin/{name}" if remote else ""),
                                    "never auto-fixed (foreign)"))
            return
        merged, via = branch_merged(name, remote=remote)
        if merged:
            action = "delete remote branch (git push origin --delete)" if remote else "delete local branch"
            findings.append(finding(
                SAFE_FIX, dim, name, f"merged, IDC-attributable {kind} branch surviving",
                action, scope=kind, merged_via=via, in_worktree=(not remote and name in wt_branches)))
        else:
            findings.append(finding(
                RISKY, dim, name, f"unmerged, IDC-attributable {kind} branch (stale?)",
                "review/merge or delete manually"))

    for b in locals_:
        classify_branch(b, "branch", remote=False)
    for b in remotes_:
        classify_branch(b, "remote-branch", remote=True)

    # ---- board ↔ issue ↔ PR coherence ----
    board = ctx.get("board")
    if board is None:
        return findings, indeterminate  # git-only mode; caller already noted "board not scanned"

    if backend == "github":
        closed_issues = ctx.get("closed_issues", set())
        issue_state = ctx.get("issue_state", {})
        issue_reason = ctx.get("issue_reason", {})
        stages_present = any(bi.get("stage") for bi in board)
        for bi in board:
            n, status, stage = bi["number"], bi.get("status"), bi.get("stage")
            v = board_coherence_verdict(status, issue_state.get(n), issue_reason.get(n, ""),
                                        n in closed_issues)
            if v:
                tier, op, detail = v
                if op == "close-issue":
                    findings.append(finding(tier, "board", f"#{n}", detail,
                                            "close the issue (gh issue close)", number=n, op=op))
                elif op == "set-done":
                    findings.append(finding(tier, "board", f"#{n}", detail,
                                            "set Status=Done", number=n, op=op, item_id=bi.get("item_id")))
                else:  # "reconcile": closed as not-planned/abandoned → RISKY, NEVER auto-set Done
                    findings.append(finding(
                        tier, "board", f"#{n}", detail,
                        "reconcile the board manually — the issue was abandoned (not-planned), not "
                        "completed; do NOT auto-set Done", number=n))
            if stages_present and not stage:
                findings.append(finding(
                    RISKY, "board", f"#{n}", "board carries a Stage field but this item has none",
                    "re-run /idc:plan to assign a Stage", number=n))
    else:
        # filesystem: no issue OPEN/CLOSED and no PRs — Status IS the state. The coherence check ties
        # board Status to git reality: an issue whose IDC build branch merged but Status != Done is the
        # filesystem "Done-but-open" analog → SAFE-FIX close (set Done).
        merged_issue_nums = set()
        locals_set = set(locals_)
        for b in locals_ + remotes_:                     # the already-fetched lists (no re-shell)
            if not is_idc(b):                            # a non-IDC branch must NEVER drive a board
                continue                                 # mutation (attribution guard) — even if its
            m = BUILD_ISSUE_RE.search(b)                 # name happens to contain a `build-<n>` token
            if not m:
                continue
            mgd, _ = branch_merged(b, remote=(b not in locals_set))  # cached from the branch scan
            if mgd:
                merged_issue_nums.add(int(m.group(1)))
        for bi in board:
            n, status = bi["number"], bi.get("status")
            if n in merged_issue_nums and status != "Done":
                findings.append(finding(
                    SAFE_FIX, "board", f"#{n}",
                    f"Status={status or 'unset'} but its IDC build branch merged",
                    "set Status=Done (close)", number=n, op="close-fs"))

    return findings, indeterminate


# --- apply-safe ------------------------------------------------------------------------------------
def apply_safe(findings, ctx):
    """Execute ONLY the SAFE-FIX findings, worktrees→local→remote→board (worktrees before their
    branches so a merged clean worktree's branch is deletable). Returns a list of (finding, ok, note)."""
    repo = ctx["repo"]
    results = []
    order = {"worktree": 0, "branch": 1, "remote-branch": 2, "board": 3}
    for f in sorted((f for f in findings if f["tier"] == SAFE_FIX), key=lambda f: order.get(f["dim"], 9)):
        dim = f["dim"]
        if dim == "worktree":
            _, rc = git(["worktree", "remove", f["name"]], repo)  # no --force: refuses if dirty
            results.append((f, rc == 0, "removed" if rc == 0 else "git worktree remove failed"))
        elif dim == "branch":
            _, rc = git(["branch", "-d", f["name"]], repo)
            if rc != 0 and f.get("merged_via") == "pr":
                _, rc = git(["branch", "-D", f["name"]], repo)  # squash-merge: git can't see ancestry
            results.append((f, rc == 0, "deleted" if rc == 0 else "git branch delete failed"))
        elif dim == "remote-branch":
            _, rc = git(["push", "origin", "--delete", f["name"]], repo)  # --delete, never --force
            results.append((f, rc == 0, "deleted on origin" if rc == 0 else "git push --delete failed"))
        elif dim == "board":
            ok, note = _apply_board(f, ctx)
            results.append((f, ok, note))
    return results


def _apply_board(f, ctx):
    op = f.get("op")
    repo = ctx["repo"]
    if op == "close-fs":
        tracker = ctx["tracker"]
        helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), "idc_tracker_fs.py")
        try:
            p = subprocess.run(["python3", helper, "--tracker", tracker, "close", "--num", str(f["number"])],
                               capture_output=True, text=True)
        except (OSError, ValueError):
            return False, "tracker close invocation failed"
        return p.returncode == 0, ("set Status=Done" if p.returncode == 0 else "tracker close failed")
    if op == "close-issue":
        try:
            p = subprocess.run(["gh", "issue", "close", str(f["number"])],
                               cwd=repo, capture_output=True, text=True)
        except (OSError, ValueError):
            return False, "gh issue close invocation failed"
        return p.returncode == 0, ("closed issue" if p.returncode == 0 else "gh issue close failed")
    if op == "set-done":
        return _github_set_status_done(f.get("item_id"), ctx)
    return False, "unknown board op"


def _github_set_status_done(item_id, ctx):
    """Set the board Status single-select to Done for one item via the `gh project item-edit` verb
    (the same idiom idc_recirc_sweep.py::stage_recirc uses — no bespoke GraphQL). Resolves the project
    NODE id (PVT_…, NOT the integer project number — the documented gotcha), the Status field id, and
    its Done option id once (cached on ctx). Fail-closed: any unresolved id → no write, reported."""
    if not item_id:
        return False, "no project item id"
    repo, owner, project = ctx["repo"], ctx["owner"], ctx["project"]
    if "status_ids" not in ctx:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import idc_gh_board
        try:
            pid = idc_gh_board._resolve_project_node_id(owner, project, repo)
        except idc_gh_board.BoardReadError:
            ctx["status_ids"] = None
            return False, "could not resolve project node id"
        fields, ok = gh_json(["project", "field-list", str(project), "--owner", owner,
                              "--format", "json"], repo)
        field_id = opt_id = None
        if ok and isinstance(fields, dict):
            for fld in (fields.get("fields") or []):
                if fld.get("name") == "Status":
                    field_id = fld.get("id")
                    for o in (fld.get("options") or []):
                        if o.get("name") == "Done":
                            opt_id = o.get("id")
        ctx["status_ids"] = (pid, field_id, opt_id) if (field_id and opt_id) else None
    ids = ctx["status_ids"]
    if not ids:
        return False, "could not resolve Status field / Done option"
    pid, field_id, opt_id = ids
    try:
        p = subprocess.run(
            ["gh", "project", "item-edit", "--id", item_id, "--project-id", pid,
             "--field-id", field_id, "--single-select-option-id", opt_id],
            cwd=repo, capture_output=True, text=True)
    except (OSError, ValueError):
        return False, "gh project item-edit invocation failed"
    return p.returncode == 0, ("set Status=Done" if p.returncode == 0 else "gh project item-edit failed")


# --- reporting -------------------------------------------------------------------------------------
def counts(findings):
    c = {SAFE_FIX: 0, REPORT_ONLY: 0, RISKY: 0}
    for f in findings:
        c[f["tier"]] = c.get(f["tier"], 0) + 1
    return c


# The single authoritative fail-closed verdict rule — exit code, JSON, and the text banner ALL derive
# from it, so the process exit that gates the e2e post-condition can never disagree with the report:
# findings win → non-zero; else an indeterminate dimension refuses a clean result; else coherent.
_VERDICT_EXIT = {"findings": 1, "coherent": 0, "indeterminate": 2}


def verdict(findings, indeterminate):
    if findings:
        return "findings"
    return "indeterminate" if indeterminate else "coherent"


def print_report(findings, ctx):
    for f in sorted(findings, key=lambda f: ({SAFE_FIX: 0, RISKY: 1, REPORT_ONLY: 2}.get(f["tier"], 3),
                                             f["dim"], f["name"])):
        act = f" (action: {f['action']})" if f.get("action") else ""
        print(f"janitor: {f['tier']} {f['dim']} {f['name']} — {f['detail']}{act}")
    if ctx.get("board") is None:
        print("janitor: board — not scanned (pass --tracker or --backend github --owner --project)")
    c = counts(findings)
    print(f"janitor: {c[SAFE_FIX]} safe-fix, {c[RISKY]} risky, {c[REPORT_ONLY]} report-only "
          f"({len(findings)} findings)")


def emit_json(findings, ctx, indeterminate, applied=None):
    c = counts(findings)
    out = {
        "verdict": verdict(findings, indeterminate),
        "counts": {"safe_fix": c[SAFE_FIX], "risky": c[RISKY], "report_only": c[REPORT_ONLY],
                   "total": len(findings)},
        "board_scanned": ctx.get("board") is not None,
        "findings": [{k: v for k, v in f.items() if k in
                      ("tier", "dim", "name", "detail", "action", "number")} for f in findings],
    }
    if applied is not None:
        out["applied"] = [{"dim": f["dim"], "name": f["name"], "ok": ok, "note": note}
                          for (f, ok, note) in applied]
    json.dump(out, sys.stdout)
    sys.stdout.write("\n")


# --- driver ----------------------------------------------------------------------------------------
def build_ctx(args):
    repo = os.path.abspath(args.repo)
    if not is_git_repo(repo):
        sys.stderr.write(f"idc-git-janitor: {repo} is not a git repository — cannot establish ground truth\n")
        sys.exit(2)
    default = default_branch(repo)
    if not default:
        sys.stderr.write("idc-git-janitor: could not resolve the default branch — cannot establish ground truth\n")
        sys.exit(2)
    trees = list_worktrees(repo)
    if trees is None:
        sys.stderr.write("idc-git-janitor: `git worktree list` failed — cannot establish ground truth\n")
        sys.exit(2)
    # Resolve the origin/<default> ref ONCE (its existence is invariant for the run) so branch_merged's
    # ancestry fallback doesn't re-`rev-parse` it per branch.
    origin_default = "refs/remotes/origin/" + default
    ctx = {"repo": repo, "default": default, "worktrees": trees, "backend": args.backend,
           "origin_default_ref": origin_default if _ref_exists(repo, origin_default) else None}

    if args.backend == "github":
        if not args.owner or not args.project:
            sys.stderr.write("idc-git-janitor: --owner and --project are required for the github backend\n")
            sys.exit(2)
        ctx["owner"], ctx["project"] = args.owner, args.project
        ctx["board"] = load_board_github(args.owner, args.project, repo)
        maps = github_merge_maps(repo)
        ctx.update(merged_refs=maps["merged_refs"], merged_oids=maps["merged_oids"],
                   closed_issues=maps["closed_issues"], issue_state=maps["issue_state"],
                   issue_reason=maps["issue_reason"])
        if maps["indeterminate"]:
            # A degraded OR capped read → the github merged-branch + board-coherence dimensions can't be
            # fully established this pass → mark indeterminate (the verdict then refuses a clean result,
            # never a hollow/partial clean).
            ctx["board_indeterminate"] = True
            if maps["capped"]:
                sys.stderr.write(
                    "idc-git-janitor: a gh list hit its --limit ceiling — the board read may be PARTIAL, "
                    "so results are INDETERMINATE this pass (do not trust a clean verdict; re-run)\n")
            else:
                sys.stderr.write("idc-git-janitor: gh pr/issue list degraded — branch/board coherence "
                                 "indeterminate this pass\n")
    elif args.tracker:
        # filesystem backend (args.backend already defaults to "filesystem").
        ctx["tracker"] = os.path.abspath(args.tracker)
        ctx["board"] = load_board_filesystem(ctx["tracker"])
    else:
        # git-only mode: no board source. Scan git; board coherence explicitly not scanned. The
        # merged-predicate falls back to ancestry (merged_refs stays empty → no PR signal).
        ctx["board"] = None
    return ctx


def main():
    ap = argparse.ArgumentParser(description="Deterministic board↔git reconciler (read-only by default).")
    ap.add_argument("--repo", default=".", help="repo dir to scan (default: cwd)")
    ap.add_argument("--backend", choices=("filesystem", "github"), default="filesystem",
                    help="tracker backend (default: filesystem)")
    ap.add_argument("--tracker", help="TRACKER.md path (filesystem backend; omit for a git-only scan)")
    ap.add_argument("--owner", help="project owner login (github backend)")
    ap.add_argument("--project", help="integer project number (github backend)")
    ap.add_argument("--apply-safe", action="store_true",
                    help="execute ONLY the SAFE-FIX tier, then re-scan and report the delta")
    ap.add_argument("--json", action="store_true", help="emit the machine-readable JSON report")
    args = ap.parse_args()

    ctx = build_ctx(args)
    findings, indeterminate = scan(ctx)

    if not args.apply_safe:
        if args.json:
            emit_json(findings, ctx, indeterminate)
        else:
            print_report(findings, ctx)
            print("janitor: " + ("COHERENT" if not findings else "findings"))
        sys.exit(_exit_code(findings, indeterminate))

    # --apply-safe: execute SAFE-FIX, re-scan, report the delta.
    if not args.json:
        print("janitor: applying SAFE-FIX tier only (RISKY + REPORT-ONLY are never touched)…")
    applied = apply_safe(findings, ctx)
    if not args.json:
        for (f, ok, note) in applied:
            mark = "✓" if ok else "✗"
            print(f"janitor: {mark} {f['dim']} {f['name']} — {note}")
    ctx2 = build_ctx(args)                       # re-establish ground truth after mutation
    findings2, indeterminate2 = scan(ctx2)
    if args.json:
        emit_json(findings2, ctx2, indeterminate2, applied=applied)
    else:
        applied_ok = sum(1 for (_f, ok, _n) in applied if ok)
        print(f"janitor: delta — {applied_ok} SAFE-FIX applied; {len(findings2)} findings remain")
        print_report(findings2, ctx2)
        print("janitor: " + ("COHERENT" if not findings2 else "findings remain (RISKY/REPORT-ONLY need review)"))
    sys.exit(_exit_code(findings2, indeterminate2))


def _exit_code(findings, indeterminate):
    return _VERDICT_EXIT[verdict(findings, indeterminate)]


if __name__ == "__main__":
    main()
