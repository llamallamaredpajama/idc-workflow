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
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

try:
    import fcntl  # POSIX advisory file locks (macOS/Linux — IDC's platforms); None elsewhere
except ImportError:  # pragma: no cover - non-POSIX fallback
    fcntl = None

# Allow importing from sibling scripts
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from idc_journal_replay import (reconstruct_state_from_entries, journal_item_id, scan_journal_strict,
                                journal_adopted, watermark_from, has_numberless_create)
import idc_reconciliation_baseline as RB

# --- attribution -----------------------------------------------------------------------------------
# IDC-attributable branch/worktree naming (the design's exact list). Anchored at the START, and `build`
# REQUIRES a `-`/`/` separator (`build-*`/`build/*`) so a foreign name that merely starts with the
# letters "build" — buildbot, buildkite, builder-x — is NOT misread as IDC. (`worktree-build-*` is still
# covered by the `worktree-` alternative.)
IDC_NAME_RE = re.compile(r"^(idc-|build[-/]|plan/|recirculate/|recirc/|worktree-)")
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
    """`{branch name → server tip SHA}` for every branch that ACTUALLY exists on `origin` right now —
    authoritative and READ-ONLY (`git ls-remote` queries the server, never mutating a local ref, so it
    is safe in the default report mode). ONE network call, not per-branch. Returns None if the remote
    can't be queried (offline / no `origin`), so the caller fail-closes the remote-branch dimension
    rather than trust possibly-stale local tracking refs. The SHA (not just the name) is load-bearing:
    a server-side RE-CREATED branch reuses a name at a NEW commit the un-pruned clone hasn't fetched, so
    the tip-match/ancestry checks must run against the SERVER tip, not the clone's stale tracking ref."""
    out, rc = git(["ls-remote", "--heads", "origin"], repo)
    if rc != 0:
        return None
    heads = {}
    for line in out.splitlines():
        parts = line.split("\trefs/heads/", 1)   # each line: "<sha>\trefs/heads/<name>"
        if len(parts) == 2 and parts[1].strip():
            heads[parts[1].strip()] = parts[0].strip()
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
JOURNAL_REL = os.path.join("docs", "workflow", "transition-journal.ndjson")
# The scanner's provenance stamp on its persisted report (round-5 finding 7): the /idc:janitor closeout
# requires it, so a hand-written report that omits it is refused (the report must come from the scanner).
JANITOR_PROVENANCE = "idc_git_janitor.py"
# The journal's advisory-lock SIDECAR, as a repo-root .gitignore pattern (always forward-slash). A
# runtime-only token both rotation and journal_append create when they lock — never committed. Derived
# from JOURNAL_REL so the ignore rule and the lock path can't drift.
JOURNAL_LOCK_GITIGNORE_LINE = JOURNAL_REL.replace(os.sep, "/") + ".lock"
TEST_STUBBORN_ENV = "IDC_JANITOR_TEST_STUBBORN_FINDING"
TEST_INTERRUPT_ENV = "IDC_JANITOR_TEST_INTERRUPT_AFTER"
BOOTSTRAP_INTERRUPT_POINT = "after-baseline-marker"
ALLOWED_PLAN_OPS = {
    "remove-worktree", "delete-local-branch", "delete-remote-branch", "close-board-item",
    "route-intake", "route-reconciliation_audit", "route-investigate",
}
OUTSIDE_BRANCH_CLASS = "outside-unmerged-branch"
OUTSIDE_MERGED_CLASS = "outside-merged-work"
OUTSIDE_DEFAULT_CLASS = "outside-default-branch"
POST_BOUNDARY_TRACKER_CLASS = "post-boundary-unreceipted-tracker"
FOREIGN_TOOL_CLASS = "foreign-tool-work"


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


def _sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def _git_bytes(args, repo):
    try:
        p = subprocess.run(["git", "-C", repo] + args, capture_output=True, check=False)
    except (OSError, ValueError):
        return b"", 127
    return p.stdout or b"", p.returncode


def _merge_base(repo, left, right):
    out, rc = git(["merge-base", left, right], repo)
    return out.strip() if rc == 0 and out.strip() else ""


def _repo_identity(repo):
    out, rc = git(["remote", "get-url", "origin"], repo)
    raw = out.strip() if rc == 0 else ""
    if raw:
        m = re.search(r"github\.com[:/]([^/]+/[^/.]+)(?:\.git)?$", raw)
        if m:
            return m.group(1)
        base = os.path.basename(raw.rstrip("/"))
        if base.endswith(".git"):
            base = base[:-4]
        parent = os.path.basename(os.path.dirname(raw.rstrip("/")))
        if parent and parent not in ("", ".", os.sep):
            return f"{parent}/{base}" if base else parent
        if base:
            return base
    return os.path.basename(os.path.abspath(repo))


def _diff_sha256(repo, base, head):
    if not base or not head:
        return ""
    raw, rc = _git_bytes(["diff", "--binary", f"{base}..{head}"], repo)
    return _sha256_hex(raw) if rc == 0 else ""


def _source_pin(repo, base, head):
    return {
        "repository": _repo_identity(repo),
        "base": base,
        "head": head,
        "diff_sha256": _diff_sha256(repo, base, head),
    }


def _read_reconciliation(repo, default):
    try:
        marker = RB.read_marker(repo)
        receipt = RB.read_receipt(repo)
        checkpoint = RB.read_checkpoint(repo)
        cursor = RB.read_cursor(repo)
        status = RB.status(repo)
        return {
            "status": status,
            "marker": marker,
            "receipt": receipt,
            "checkpoint": checkpoint,
            "cursor": cursor,
            "error": None,
            "default_branch": (marker or receipt or {}).get("default_branch") or {
                "name": default,
                "head": tip_sha(repo, "refs/heads/" + default),
            },
        }
    except RB.BaselineError as exc:
        return {
            "status": {
                "schema_version": RB.SCHEMA_VERSION,
                "state": RB.PENDING_STATE,
                "pending": True,
                "marker_present": False,
                "receipt_present": False,
                "checkpoint_present": False,
                "cursor_present": False,
                "marker_path": RB.MARKER_RELPATH,
                "receipt_path": RB.RECEIPT_RELPATH,
                "checkpoint_path": RB.CHECKPOINT_RELPATH,
                "cursor_path": RB.CURSOR_BASENAME,
                "default_branch": {"name": default, "head": tip_sha(repo, "refs/heads/" + default)},
                "reason": RB.REQUIRED_REASON,
            },
            "marker": None,
            "receipt": None,
            "checkpoint": None,
            "cursor": None,
            "error": str(exc),
            "default_branch": {"name": default, "head": tip_sha(repo, "refs/heads/" + default)},
        }


def _journal_suffix_item_ids(ctx):
    receipt = ctx.get("reconciliation", {}).get("receipt")
    if not receipt:
        return set(), None
    journal_path = os.path.join(ctx["repo"], JOURNAL_REL)
    if not os.path.exists(journal_path):
        return set(), "missing"
    entries, error = scan_journal_strict(journal_path)
    if error:
        return set(), error
    start = int(receipt.get("journal_entry_count") or 0)
    return {journal_item_id(e) for e in entries[start:] if journal_item_id(e) is not None}, None


def _legacy_item_snapshot(board):
    out = []
    for item in board or []:
        if item.get("number") is None:
            continue
        out.append({
            "number": item["number"],
            "stage": item.get("stage") or "",
            "status": item.get("status") or "",
            "evidence_class": RB.ADOPTED_STATE,
            "historical_verification": "not-claimed",
        })
    return sorted(out, key=lambda it: it["number"])


def _current_ref_snapshots(ctx):
    repo = ctx["repo"]
    default = ctx["default"]
    refs = []
    for branch in sorted(local_branches(repo)):
        if branch == default:
            continue
        refs.append({
            "name": branch,
            "kind": "local_branch",
            "head": tip_sha(repo, "refs/heads/" + branch),
            "foreign_tool": foreign_label(branch),
            "idc_attributable": is_idc(branch),
        })
    return refs


def _post_boundary_tracker_findings(ctx):
    receipt = ctx.get("reconciliation", {}).get("receipt")
    board = ctx.get("board") or []
    if not receipt:
        return [], False
    suffix_ids, journal_error = _journal_suffix_item_ids(ctx)
    if journal_error:
        return [finding(
            RISKY,
            "baseline",
            "journal",
            f"could not establish post-boundary journal coverage ({journal_error})",
            "re-run Janitor after journal state is readable",
            classification=POST_BOUNDARY_TRACKER_CLASS,
            root_id="post-boundary-journal",
            route="reconciliation_audit",
            preserve=True,
            blocker=True,
        )], True
    legacy = {
        int(item["number"]): {
            "stage": item.get("stage") or "",
            "status": item.get("status") or "",
        }
        for item in receipt.get("legacy_items") or []
        if isinstance(item, dict) and isinstance(item.get("number"), int)
    }
    findings = []
    for item in board:
        number = item.get("number")
        if not isinstance(number, int):
            continue
        state = {"stage": item.get("stage") or "", "status": item.get("status") or ""}
        if number in legacy and legacy[number] == state:
            continue
        if number in suffix_ids:
            continue
        findings.append(finding(
            RISKY,
            "baseline",
            f"#{number}",
            "post-boundary tracker state changed without a matching journal suffix since adoption",
            "route a reconciliation audit; do not claim historical verification",
            number=number,
            classification=POST_BOUNDARY_TRACKER_CLASS,
            root_id=f"post-boundary-item:#{number}",
            route="reconciliation_audit",
            preserve=True,
            blocker=True,
        ))
    return findings, False


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
    live = None   # {name → server-tip sha} once resolved; stays None if there are no remote refs to verify
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
    receipt = ctx.get("reconciliation", {}).get("receipt")
    adopted_ref_names = {
        ref.get("name") for ref in (receipt.get("adopted_refs") or [])
        if isinstance(ref, dict) and isinstance(ref.get("name"), str)
    } if receipt else set()
    _merged_cache = {}

    def branch_merged(short, remote=False):
        key = (short, remote)
        if key in _merged_cache:
            return _merged_cache[key]
        if remote:
            # A remote branch's ONLY authoritative tip is the SERVER's (from ls-remote), NEVER the clone's
            # possibly-stale local tracking ref: a server-side RE-CREATED branch reuses the name at a NEW
            # commit the un-pruned clone hasn't fetched. Run BOTH the PR-head-oid match AND ancestry
            # against that server tip — a re-created (or unfetched) tip fails the oid match and fails
            # ancestry (an unknown/newer commit is not an ancestor of the default) → RISKY, never a
            # --apply-safe delete of live re-created work. (remotes_ is already filtered to names present
            # in `live`, so the server tip is available here.)
            server_tip = live.get(short) if live else None
            if short in merged_refs and pr_signal_ok(merged_oids.get(short), server_tip):
                res = (True, "pr")
            elif server_tip and (is_ancestor(repo, server_tip, default)
                                 or (origin_default_ref and is_ancestor(repo, server_tip, origin_default_ref))):
                res = (True, "ancestry")
            else:
                res = (False, "")
        else:
            ref = "refs/heads/" + short
            # The merged-PR head-ref set is the authoritative github signal — but ONLY if the branch's tip
            # STILL equals the PR's merged head commit (pr_signal_ok). A name reused for divergent new work
            # must NOT read as merged (else --apply-safe force-deletes live commits); it falls through to
            # ancestry, which a divergent tip fails → RISKY. Off github merged_refs is empty → straight to
            # ancestry.
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
            label = foreign_label(name)
            receipt = ctx.get("reconciliation", {}).get("receipt")
            pending_baseline = bool((ctx.get("reconciliation", {}).get("status") or {}).get("pending"))
            head = tip_sha(repo, "refs/heads/" + name) if wt.get("branch") else ""
            base = _merge_base(repo, "refs/heads/" + name, default) if wt.get("branch") else ""
            if receipt and name in adopted_ref_names:
                continue
            if (receipt or pending_baseline) and label == "unknown" and wt.get("branch") and name not in adopted_ref_names:
                findings.append(finding(
                    RISKY, "worktree", path,
                    f"outside-path worktree on '{name}' is preserved for Intake adoption",
                    "preserve and route through Intake/Build adoption",
                    classification=OUTSIDE_BRANCH_CLASS,
                    root_id=f"outside-branch:{name}",
                    route="intake",
                    preserve=True,
                    source_pin=_source_pin(repo, base, head),
                ))
            else:
                findings.append(finding(
                    REPORT_ONLY, "worktree", path,
                    f"non-IDC ({label}) worktree on '{name}'", "never auto-fixed (foreign)",
                    classification=FOREIGN_TOOL_CLASS,
                    root_id=f"foreign-worktree:{name}",
                    route="investigate",
                    preserve=True,
                ))
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
            label = foreign_label(name)
            receipt = ctx.get("reconciliation", {}).get("receipt")
            pending_baseline = bool((ctx.get("reconciliation", {}).get("status") or {}).get("pending"))
            ref = ("refs/remotes/origin/" + name) if remote else ("refs/heads/" + name)
            head = live.get(name) if remote and live else tip_sha(repo, ref)
            if receipt and name in adopted_ref_names:
                return
            if (receipt or pending_baseline) and label == "unknown" and name not in adopted_ref_names:
                merged, _via = branch_merged(name, remote=remote)
                base = _merge_base(repo, ref, default)
                findings.append(finding(
                    RISKY, dim, name,
                    ("already-merged outside-path work" if merged else "outside-path branch") +
                    (f" on origin/{name}" if remote else f" on {name}"),
                    "route to a reconciliation audit" if merged else "preserve and route through Intake/Build adoption",
                    classification=OUTSIDE_MERGED_CLASS if merged else OUTSIDE_BRANCH_CLASS,
                    root_id=f"outside-branch:{name}",
                    route="reconciliation_audit" if merged else "intake",
                    preserve=True,
                    source_pin=_source_pin(repo, base, head),
                ))
                return
            detail = f"non-IDC ({label}) {kind} branch"
            findings.append(finding(REPORT_ONLY, dim, name,
                                    detail + (f" origin/{name}" if remote else ""),
                                    "never auto-fixed (foreign)",
                                    classification=FOREIGN_TOOL_CLASS,
                                    root_id=f"foreign-branch:{name}",
                                    route="investigate",
                                    preserve=True))
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

    # ---- RESUME-RECIRC: a recirculator killed mid-drain (both backends) ----
    # The signature of a truncated recirc drain: an OPEN recirc branch/PR still coexists with an OPEN
    # recirculation inbox. This ADDITIVE correlation finding (the unmerged `recirculate/*` branch is
    # ALREADY reported RISKY on its own) tells the next session to resume `/idc:recirculate`. It
    # composes from data already in hand — the loaded board + the branch scans' cached merge verdicts —
    # so it adds NO board read or gh call (the single-board-read promise).
    #   OPEN inbox  = a board item with stage == "Recirculation" and status != "Done".
    #   OPEN branch = a `recirculate/*` OR `recirc/*` branch (local or remote) that is NOT merged (an
    #                 open-PR proxy on the filesystem backend). Judged via branch_merged (server tip for
    #                 remotes). BOTH prefixes are IDC recirc branches (IDC_NAME_RE), so both must resume.
    _recirc_pfx = ("recirculate/", "recirc/")
    open_inbox = [bi for bi in board
                  if bi.get("stage") == "Recirculation" and bi.get("status") != "Done"]
    open_recirc = [b for b in locals_
                   if b.startswith(_recirc_pfx) and not branch_merged(b, remote=False)[0]]
    open_recirc += [b for b in remotes_
                    if b.startswith(_recirc_pfx) and not branch_merged(b, remote=True)[0]]
    if open_inbox and open_recirc:
        b0 = sorted(open_recirc)[0]
        n_inbox = len(open_inbox)
        findings.append(finding(
            RISKY, "recirc", "RESUME-RECIRC",
            f"open recirc branch {b0} + {n_inbox} open Stage=Recirculation ticket(s) — a mid-drain "
            f"truncation; resume /idc:recirculate", action="resume the recirc drain"))

    receipt = ctx.get("reconciliation", {}).get("receipt")
    if receipt:
        baseline_head = (receipt.get("default_branch") or {}).get("head") or ""
        current_head = tip_sha(repo, "refs/heads/" + default)
        if baseline_head and current_head and current_head != baseline_head:
            findings.append(finding(
                RISKY,
                "baseline",
                default,
                "default-branch head moved after adoption without a same-path IDC receipt binding",
                "route a reconciliation audit for the post-boundary default-branch diff",
                classification=OUTSIDE_DEFAULT_CLASS,
                root_id=f"outside-default:{current_head}",
                route="reconciliation_audit",
                preserve=True,
                source_pin=_source_pin(repo, baseline_head, current_head),
            ))
        extra_findings, extra_indeterminate = _post_boundary_tracker_findings(ctx)
        findings.extend(extra_findings)
        indeterminate = indeterminate or extra_indeterminate

    return findings, indeterminate


# --- apply-safe ------------------------------------------------------------------------------------
def _tier_rank(tier):
    return {SAFE_FIX: 3, RISKY: 2, REPORT_ONLY: 1}.get(tier, 0)


def dedupe_findings(findings):
    grouped = {}
    for raw in findings:
        root_id = raw.get("root_id") or f"{raw.get('dim')}:{raw.get('name')}"
        item = dict(raw)
        item.setdefault("root_id", root_id)
        item.setdefault("symptoms", [])
        item["symptoms"] = [*item.get("symptoms", []), f"{item.get('dim')}:{item.get('name')}"]
        current = grouped.get(root_id)
        if current is None:
            grouped[root_id] = item
            continue
        current["symptoms"] = sorted(set(current.get("symptoms", [])) | set(item["symptoms"]))
        current["blocker"] = bool(current.get("blocker") or item.get("blocker"))
        if item.get("preserve"):
            current["preserve"] = True
        if item.get("source_pin") and not current.get("source_pin"):
            current["source_pin"] = item["source_pin"]
        if item.get("route") and not current.get("route"):
            current["route"] = item["route"]
        if item.get("classification") and not current.get("classification"):
            current["classification"] = item["classification"]
        if _tier_rank(item.get("tier")) > _tier_rank(current.get("tier")):
            merged = dict(item)
            merged["symptoms"] = current["symptoms"]
            merged["blocker"] = current["blocker"]
            if current.get("preserve"):
                merged["preserve"] = True
            if current.get("source_pin") and not merged.get("source_pin"):
                merged["source_pin"] = current["source_pin"]
            grouped[root_id] = merged
    return list(grouped.values())


def _plan_op(f):
    if f.get("tier") == SAFE_FIX:
        return {
            "worktree": "remove-worktree",
            "branch": "delete-local-branch",
            "remote-branch": "delete-remote-branch",
            "board": "close-board-item",
        }.get(f.get("dim"))
    route = f.get("route")
    if route == "intake":
        return "route-intake"
    if route == "reconciliation_audit":
        return "route-reconciliation_audit"
    if route == "investigate":
        return "route-investigate"
    return None


def build_plan(findings):
    ops = []
    blockers = []
    for f in findings:
        root_id = f.get("root_id") or f"{f.get('dim')}:{f.get('name')}"
        if f.get("blocker"):
            blockers.append(root_id)
        op = _plan_op(f)
        if not op:
            continue
        ops.append({
            "root_id": root_id,
            "op": op,
            "tier": f.get("tier"),
            "route": f.get("route"),
            "classification": f.get("classification"),
            "name": f.get("name"),
            "preserve": bool(f.get("preserve")),
            "source_pin": f.get("source_pin"),
        })
    validated = all(op["op"] in ALLOWED_PLAN_OPS and not (op["op"].startswith("delete") and op.get("preserve")) for op in ops)
    return {
        "validated": validated,
        "operations": ops,
        "blockers": sorted(set(blockers)),
    }


def apply_safe(findings, ctx):
    """Execute ONLY the SAFE-FIX findings, worktrees→local→remote→board (worktrees before their
    branches so a merged clean worktree's branch is deletable). Returns a list of (finding, ok, note).

    A SAFE-FIX board close is REFUSED when the same item already carries a journal divergence finding:
    closing the issue or stamping Done there would launder an unsupported raw terminal state into a
    sanctioned clean-up. The journal mismatch must be reconciled first, never paved over by Janitor.
    """
    repo = ctx["repo"]
    results = []
    blocked_board_nums = {f.get("number") for f in findings
                          if f.get("dim") == "journal" and f.get("number") is not None}
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
            if f.get("number") in blocked_board_nums:
                results.append((f, False,
                                "refused: the same item already has a journal divergence finding — "
                                "reconcile sanctioned history before any SAFE-FIX board close"))
                continue
            ok, note = _apply_board(f, ctx)
            results.append((f, ok, note))
    return results


def _journal_board_fix(ctx, backend, number, verified):
    """A SAFE-FIX board close is a sanctioned mutation, so it lands in the SAME canonical transition
    journal the engine writes — otherwise the --apply-safe re-scan immediately reports the janitor's
    own fix as a journal↔board divergence and the apply pass can never converge. Best-effort by the
    journal contract: the close already happened, a journal failure must not fail the fix.

    Recorded as the janitor's OWN op kind — `janitor-repair`, carrying the deterministic truth the
    SAFE-FIX classifier verified (`verified` = the finding detail: the merged IDC branch / merged-PR
    close / CLOSED-as-completed state) — NEVER as an engine `close` (codex round-12 P1): the engine's
    `close` is a GUARDED door (a valid, passing, item-owning verdict) and a look-alike record would
    launder the janitor's reconciliation into a sanctioned guarded close in the audit trail. The
    janitor DECIDES nothing here — it stamps Done only when the truth already happened elsewhere —
    so its record must disclose exactly that. Replay is unaffected by the op name: reconstruction
    reads the structured `item` + `to` fields, and the corroboration/watermark scans key on
    create/link/restage/intake ops only."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import idc_transition
    tracker = ctx.get("tracker")
    tracker_rel = os.path.relpath(tracker, ctx["repo"]) if (backend == "filesystem" and tracker) else None
    idc_transition.journal_append(ctx["repo"], "janitor-repair", backend, tracker_rel,
                                  {"num": number, "to_status": "Done", "agent": "janitor",
                                   "disposition_evidence": {"door": "janitor-safe-fix",
                                                            "verified": verified}})


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
        if p.returncode == 0:
            _journal_board_fix(ctx, "filesystem", f["number"], f.get("detail") or "merged IDC build branch")
        return p.returncode == 0, ("set Status=Done" if p.returncode == 0 else "tracker close failed")
    if op == "close-issue":
        # Closes the GitHub issue only — the board Status is already Done, so replay state is
        # unchanged and there is nothing to journal.
        try:
            p = subprocess.run(["gh", "issue", "close", str(f["number"])],
                               cwd=repo, capture_output=True, text=True)
        except (OSError, ValueError):
            return False, "gh issue close invocation failed"
        return p.returncode == 0, ("closed issue" if p.returncode == 0 else "gh issue close failed")
    if op == "set-done":
        ok, note = _github_set_status_done(f.get("item_id"), ctx)
        if ok:
            _journal_board_fix(ctx, "github", f["number"], f.get("detail") or "issue completed on GitHub")
        return ok, note
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
# indeterminate dimensions win (fail closed); else findings are actionable; else coherent.
_VERDICT_EXIT = {"findings": 1, "coherent": 0, "indeterminate": 2}
# The documented ground-truth-unestablished exit (a build_ctx failure or an indeterminate scan). The
# only exit that grounds a /idc:janitor `blocked_external` — round-5 finding 7 writes the report on it.
_JANITOR_BLOCKED_EXIT = _VERDICT_EXIT["indeterminate"]
# The human banner for each verdict. Kept in lockstep with _VERDICT_EXIT so the printed line NEVER
# disagrees with the exit code (the nit this closes: an indeterminate scan — exit 2 — used to print
# "COHERENT").
_VERDICT_BANNER = {"coherent": "COHERENT", "findings": "findings", "indeterminate": "INDETERMINATE"}


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


def emit_json(findings, ctx, indeterminate, applied=None, plan=None):
    c = counts(findings)
    baseline = dict((ctx.get("reconciliation") or {}).get("status") or {})
    if (ctx.get("reconciliation") or {}).get("error"):
        baseline["error"] = ctx["reconciliation"]["error"]
    out = {
        "verdict": verdict(findings, indeterminate),
        "counts": {"safe_fix": c[SAFE_FIX], "risky": c[RISKY], "report_only": c[REPORT_ONLY],
                   "total": len(findings)},
        "board_scanned": ctx.get("board") is not None,
        "baseline": baseline,
        # `op` rides the JSON (never the human report) because it is the finding's MACHINE
        # classification — the stable token a programmatic consumer filters on instead of
        # pattern-matching the prose `detail`. idc_finish_coherence.py selects the board-stale class
        # (`set-done` / `close-fs`) by exactly this key; without it that consumer would have to grep
        # English, which drifts the moment a detail string is reworded. Additive: a finding with no
        # `op` (every non-board dimension) simply omits the key, so existing consumers are unchanged.
        "findings": [{k: v for k, v in f.items() if k in
                      ("tier", "dim", "name", "detail", "action", "number", "op", "classification",
                       "route", "preserve", "root_id", "source_pin", "symptoms", "blocker")} for f in findings],
    }
    if plan is not None:
        out["plan"] = plan
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
    ctx["reconciliation"] = _read_reconciliation(repo, default)

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


def check_journal_divergence(ctx, findings, journal_path):
    """Compare journal-reconstructed state with actual board state.

    Returns True when the journal dimension is indeterminate (missing/corrupt/unreadable in a repo that
    has board state), so the caller exits 2 instead of downgrading journal corruption to advisory debris.
    """
    board = ctx.get("board")
    if board is None:
        return False # Cannot check divergence without a board
    if not os.path.exists(journal_path):
        # The transition journal is created lazily, so absence is clean ONLY on a fresh (empty)
        # board. A non-empty board with no journal means journal-backed history is missing
        # (deleted, or the board was mutated outside the engine) → indeterminate, fail closed.
        if board:
            sys.stderr.write("idc-git-janitor: board has items but %s is missing — "
                             "journal dimension indeterminate\n" % journal_path)
            return True
        return False

    # ONE locked, fail-closed snapshot feeds the whole pass: the reconstruction, the adoption
    # watermark, and the carve-out guard below (#154's codex P2). The two INDEPENDENT UNLOCKED reads
    # this replaces could disagree — a `/idc:doctor` run overlapping an engine append could read a
    # half-written line and report a corrupt journal, and one overlapping a janitor rotation could
    # miss records already moved to the archive and report divergence — both false. scan_journal_strict
    # takes the journal's sidecar lock (the shared convention with journal_append and rotation), so a
    # concurrent writer is waited out rather than read through.
    entries, error = scan_journal_strict(journal_path)
    if error:
        sys.stderr.write("idc-git-janitor: the transition journal could not be read consistently "
                         "(%s) — journal dimension indeterminate\n" % error)
        return True
    expected_state = reconstruct_state_from_entries(entries)
    create_watermark = watermark_from(entries)
    # A NUMBERLESS create record VOIDS the numbered watermark as an adoption lower bound: on the
    # github backend a create whose issue-number read-back failed journals only its project_item_id,
    # so the TRUE first create may be that numberless one and an item numbered below the first
    # NUMBERED create can still be post-adoption. Granting it the legacy carve-out anyway is fail
    # OPEN — the board-only item's missing history reads as "predates journaling" and doctor Row 10
    # reports board↔git coherent (#155). So the carve-out is disabled outright while any numberless
    # create is on record, exactly as the engine's dispose corroboration already does
    # (idc_transition._journal_corroboration); this path was simply never wired to the same helper.
    numberless_create = has_numberless_create(entries)
    # No create record at all → journaling has not begun: a genuinely pre-journal board, where every
    # board-only item is legacy. (Kept explicit: with a numberless-only journal, watermark_from is
    # ALSO None, and those two Nones mean opposite things.)
    adopted = journal_adopted(entries)

    actual_state = {}
    for item in board:
        item_id = item.get("number")
        if item_id is not None:
            actual_state[item_id] = {
                "stage": item.get("stage") or "",
                "status": item.get("status")
            }

    all_item_ids = set(expected_state.keys()) | set(actual_state.keys())
    for item_id in sorted(all_item_ids):
        expected_item = expected_state.get(item_id, {})
        actual_item = actual_state.get(item_id, {})

        if not actual_item:
            findings.append(finding(RISKY, "journal", f"#{item_id}",
                "Item present in journal but missing from board.", "reconcile manually", number=item_id))
            continue
        if not expected_item:
            # Board-only items are tolerated ONLY below the derived adoption watermark (the earliest
            # journaled create — item numbers are monotonic on both backends): those predate
            # journaling (legacy). An item ABOVE the watermark was created after create-journaling
            # began, so a total absence of journal lines means lost (truncated) or bypassed history.
            if not adopted:
                continue  # pre-journal board: no create record at all, so nothing to be above.
            if numberless_create:
                findings.append(finding(RISKY, "journal", f"#{item_id}",
                    "Item has no journal history, and a journaled create carries no item number "
                    "(the github issue-number read-back gap) — the adoption watermark is unreliable, "
                    "so the pre-journal carve-out cannot be granted", "reconcile manually", number=item_id))
            elif create_watermark is not None and item_id > create_watermark:
                findings.append(finding(RISKY, "journal", f"#{item_id}",
                    "Item has no journal history but was created after journaling began "
                    f"(numbered above journaled create #{create_watermark})", "reconcile manually", number=item_id))
            continue

        act_stage = actual_item.get("stage")
        act_status = actual_item.get("status")

        if "stage" in expected_item and expected_item.get("stage") != act_stage:
            detail = (f"Stage mismatch: journal says '{expected_item.get('stage')}', "
                      f"board says '{act_stage}'")
            findings.append(finding(RISKY, "journal", f"#{item_id}", detail, "reconcile manually", number=item_id))

        if "status" in expected_item and expected_item.get("status") != act_status:
            detail = (f"Status mismatch: journal says '{expected_item.get('status')}', "
                      f"board says '{act_status}'")
            findings.append(finding(RISKY, "journal", f"#{item_id}", detail, "reconcile manually", number=item_id))

    return False


def _read_journal_bytes(journal_path):
    """Read the active journal as raw bytes. A single seam — so rotation knows the EXACT offset a
    concurrent journal_append would write past (below), and so the rotation/append-race governance test
    can deterministically inject that append right after the read."""
    with open(journal_path, "rb") as f:
        return f.read()


def journal_lock_path(journal_path):
    """The STABLE sidecar lock path for the journal (`<journal>.lock`). The shared convention with the
    engine's journal_append: both take fcntl.flock(LOCK_EX) on THIS file — never the journal itself —
    so the exclusive lock survives rotation's atomic os.replace of the journal inode. idc_ledger locks
    a `.lock` sidecar for exactly this reason (os.replace orphans a lock held on the renamed inode)."""
    return journal_path + ".lock"


def _lock_journal_sidecar(journal_path):
    """Take fcntl.flock(LOCK_EX) on the journal's STABLE sidecar and return the held fd (close it to
    release), or None if fcntl is unavailable / the lock could not be taken.

    Because the sidecar inode never changes, an appender that takes the SAME lock and then waits here
    wakes only AFTER rotation's replace and opens the CURRENT journal — so no write ever lands on the
    replaced inode. BEST-EFFORT: a failure returns None and the caller proceeds unlocked (relying on
    the drain fallback); it never blocks forever nor fails the janitor."""
    if fcntl is None:
        return None
    try:
        fh = open(journal_lock_path(journal_path), "w", encoding="utf-8")
    except OSError:
        return None
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    except OSError:
        try:
            fh.close()
        except OSError:
            pass
        return None
    return fh


def _drain_replaced_inode(old_fd, consumed):
    """Bytes a concurrent journal_append wrote to the journal inode PAST `consumed` while rotation ran.

    `old_fd` is an fd held open on the journal's inode from BEFORE the read. After rotation's atomic
    os.replace unlinks that inode from the path, the inode itself persists while this fd (and any
    appender's fd opened before the replace) stays open — so reading here recovers every append that
    landed on the replaced inode DURING the whole rotation, including the read→replace window. This is
    the FALLBACK that still protects an UNLOCKED appender (fcntl absent, or the engine's appender-side
    lock not yet deployed); with both sides locking, no concurrent append lands and this reads empty.
    journal_append is O_APPEND, so those bytes only ever extend past `consumed`. Empty on any error."""
    try:
        old_fd.seek(consumed)
        return old_fd.read()
    except OSError:
        return b""


def ensure_lock_gitignored(repo_root):
    """Idempotently + NON-DESTRUCTIVELY add the journal's advisory-lock sidecar to the repo-root
    `.gitignore` — a runtime-only token both rotation and journal_append create when they lock, never
    committed (the same sidecar treatment the ledger/drain-verdict got in v4 Phase 3 Stage A).

    Governed-repo-gated (a no-op without docs/workflow/tracker-config.yaml, so a stray call never
    litters a non-IDC dir). APPEND-ONLY — never rewrites an operator's existing `.gitignore` lines.
    Prints `journal-lock-gitignore-added` / `journal-lock-gitignore-already-present`; a `.gitignore`
    write failure warns to stderr and is a no-op (best-effort scaffold step)."""
    if not os.path.isfile(os.path.join(repo_root, "docs", "workflow", "tracker-config.yaml")):
        return  # not a governed repo — no-op
    line = JOURNAL_LOCK_GITIGNORE_LINE
    gi = os.path.join(repo_root, ".gitignore")
    try:
        existing = ""
        if os.path.isfile(gi):
            with open(gi, encoding="utf-8") as fh:
                existing = fh.read()
        if any(ln.strip() == line for ln in existing.splitlines()):
            print("journal-lock-gitignore-already-present")
            return
        with open(gi, "a", encoding="utf-8") as fh:
            if existing and not existing.endswith("\n"):
                fh.write("\n")
            fh.write("# IDC transition-journal advisory lock (runtime sidecar; do not commit)\n")
            fh.write(line + "\n")
        print("journal-lock-gitignore-added")
    except OSError as e:
        sys.stderr.write(f"idc-git-janitor: could not ensure .gitignore in {repo_root}: {e}\n")


def rotate_journal(ctx, journal_path):
    """Archive journal entries for terminal items and atomically rewrite the active journal.

    The rewrite stays a SINGLE atomic os.replace. The race between rotation's read and that replace (a
    concurrent journal_append landing in between, dropped by the old code — issue #150 round-10 P2) is
    closed by holding an fcntl.flock(LOCK_EX) on the journal's STABLE SIDECAR (`<journal>.lock`, never
    replaced) across the whole critical section: the engine's journal_append takes the SAME sidecar
    lock, so append and rotation serialise on a stable inode — an appender that waited wakes after the
    replace and opens the CURRENT journal, never the replaced one (idc_ledger's sidecar-lock precedent).
    Locking is BEST-EFFORT — on any flock failure it warns and proceeds unlocked. As the lock-failure
    (and unlocked-appender) fallback, rotation also holds an fd on the pre-rotation journal inode and
    DRAINS, after the replace, any bytes an unlocked appender wrote to it during rotation, re-appending
    them so no sanctioned append is ever lost."""
    board = ctx.get("board")
    if board is None:
        sys.stderr.write("idc-git-janitor: cannot rotate journal without a board. Use --tracker or --backend github.\n")
        sys.exit(2)

    terminal_items = {item["number"] for item in board if item.get("status") == "Done"}
    if not terminal_items:
        print("No terminal items found on board. Nothing to rotate.")
        return

    if not os.path.exists(journal_path):
        # Terminal items exist (checked above) but their journal history is gone — the same
        # non-empty-board/missing-journal state the scan treats as indeterminate. Refusing keeps
        # lost history from reading as successful maintenance.
        sys.stderr.write(f"idc-git-janitor: board has terminal items but {journal_path} is missing — "
                         "refusing to rotate (journal history indeterminate)\n")
        sys.exit(2)

    # Take the exclusive SIDECAR lock (serialising a locked journal_append) for the whole critical
    # section, AND hold an fd on the current journal inode for the DRAIN fallback (an unlocked appender
    # that slipped in). Both best-effort: a lock failure warns and proceeds unlocked, relying on the drain.
    lock_fh = _lock_journal_sidecar(journal_path)
    if fcntl is not None and lock_fh is None:
        sys.stderr.write("idc-git-janitor: could not take the journal sidecar lock for rotation — "
                         "proceeding unlocked (best-effort; the post-replace drain still recovers appends)\n")
    try:
        old_fd = open(journal_path, "rb")
    except OSError:
        old_fd = None

    # Read the journal as bytes through the seam so `consumed` is the exact offset a concurrent
    # journal_append (during rotation) would write past.
    raw = _read_journal_bytes(journal_path)
    consumed = len(raw)
    to_archive = []
    to_keep = []
    # Split on the NDJSON newline BYTE (0x0A) ONLY — NOT str.splitlines(), which also breaks on Unicode
    # line/paragraph separators (U+2028/U+2029). json.dumps(ensure_ascii=False) emits those UNescaped
    # (issue titles flow into `what`), so a VALID record carrying one would be split mid-record and
    # wrongly rejected as malformed. 0x0A never occurs inside a multi-byte UTF-8 sequence, so a byte
    # split is exact; re-attach the delimiter so each kept line is byte-identical to the original.
    byte_lines = raw.split(b"\n")
    if byte_lines and byte_lines[-1] == b"":
        byte_lines.pop()   # the empty tail after the journal's final newline — not a record
    for line_num, bline in enumerate(byte_lines, 1):
        line = bline.decode("utf-8") + "\n"
        if not line.strip():
            to_keep.append(line)
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as e:
            sys.stderr.write(f"idc-git-janitor: malformed journal line {line_num}: {e.msg}\n")
            sys.exit(2)
        if not isinstance(entry, dict):
            sys.stderr.write(f"idc-git-janitor: malformed journal line {line_num}: expected object\n")
            sys.exit(2)
        item_id = journal_item_id(entry)
        if item_id in terminal_items:
            to_archive.append(line)
        else:
            to_keep.append(line)

    if not to_archive:
        # Not rotating (no replace) — release the drain fd and the sidecar lock; the live journal is intact.
        for fh in (old_fd, lock_fh):
            if fh is not None:
                try:
                    fh.close()
                except OSError:
                    pass
        print("No journal entries found for terminal items. Nothing to rotate.")
        return

    now = datetime.datetime.now(datetime.timezone.utc)
    archive_dir = os.path.join(ctx["repo"], "docs/workflow/journal-archive")
    os.makedirs(archive_dir, exist_ok=True)
    os.makedirs(os.path.dirname(journal_path), exist_ok=True)
    archive_path = os.path.join(archive_dir, f"{now.strftime('%Y-%m-%d')}.ndjson")

    existing_archive = []
    if os.path.exists(archive_path):
        with open(archive_path, "r", encoding="utf-8") as f:
            existing_archive = f.readlines()

    archive_tmp = None
    journal_tmp = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=archive_dir, delete=False) as tmp:
            tmp.writelines(existing_archive)
            tmp.writelines(to_archive)
            tmp.flush()
            os.fsync(tmp.fileno())
            archive_tmp = tmp.name

        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=os.path.dirname(journal_path), delete=False) as tmp:
            tmp.writelines(to_keep)
            tmp.flush()
            os.fsync(tmp.fileno())
            journal_tmp = tmp.name

        os.replace(archive_tmp, archive_path)
        archive_tmp = None
        os.replace(journal_tmp, journal_path)
        journal_tmp = None

        # DRAIN the replaced inode (issue #150 round-10 P2 fallback): while the flock serialises a
        # LOCKED appender, this recovers any UNLOCKED appender (fcntl absent, or the engine's
        # appender-side lock not yet deployed) that wrote to the pre-rotation inode DURING rotation —
        # including the read→replace window — re-appending it so no sanctioned append is lost. With both
        # sides locking, no concurrent append landed and this reads empty. A drained line for a
        # since-terminal item is harmlessly kept and archived next rotation.
        if old_fd is not None:
            leftover = _drain_replaced_inode(old_fd, consumed)
            if leftover:
                with open(journal_path, "ab") as jt:
                    jt.write(leftover)
                    jt.flush()
                    os.fsync(jt.fileno())
    finally:
        for fh in (old_fd, lock_fh):   # close the drain fd, then release the sidecar lock (lock_fh)
            if fh is not None:
                try:
                    fh.close()
                except OSError:
                    pass
        for path in (archive_tmp, journal_tmp):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass

    print(f"Archived {len(to_archive)} journal entries to {archive_path}")
    print(f"Journal rotated. {len(to_keep)} entries remain.")


def _route_obligations(findings):
    obligations = []
    seen = set()
    for f in findings:
        route = f.get("route")
        if route not in ("intake", "reconciliation_audit", "investigate"):
            continue
        root_id = f.get("root_id") or f"{f.get('dim')}:{f.get('name')}"
        if root_id in seen:
            continue
        seen.add(root_id)
        obligations.append({
            "root_id": root_id,
            "classification": f.get("classification"),
            "route": route,
            "name": f.get("name"),
            "source_pin": f.get("source_pin"),
            "preserve": bool(f.get("preserve")),
        })
    return obligations


def _bootstrap_receipt(ctx, findings):
    board = ctx.get("board") or []
    prior = ctx.get("reconciliation", {}).get("receipt") or {}
    journal_path = os.path.join(ctx["repo"], JOURNAL_REL)
    journal_count = 0
    if os.path.exists(journal_path):
        entries, error = scan_journal_strict(journal_path)
        if not error:
            journal_count = len(entries)
    merged_obligations = {}
    for item in prior.get("routed_obligations") or []:
        if isinstance(item, dict) and isinstance(item.get("root_id"), str):
            merged_obligations[item["root_id"]] = item
    for item in _route_obligations(findings):
        merged_obligations[item["root_id"]] = item
    return {
        "schema_version": RB.SCHEMA_VERSION,
        "state": RB.ADOPTED_STATE,
        "created_at": prior.get("created_at") or datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
        "default_branch": {
            "name": ctx["default"],
            "head": tip_sha(ctx["repo"], "refs/heads/" + ctx["default"]),
        },
        "journal_entry_count": journal_count,
        "legacy_items": _legacy_item_snapshot(board),
        "adopted_refs": _current_ref_snapshots(ctx),
        "routed_obligations": [merged_obligations[key] for key in sorted(merged_obligations)],
        "unresolved": [],
    }


def _checkpoint_payload(findings, *, advanced):
    return {
        "schema_version": RB.SCHEMA_VERSION,
        "resolved_root_ids": sorted({
            (f.get("root_id") or f"{f.get('dim')}:{f.get('name')}")
            for f in findings if not f.get("blocker")
        }),
        "blocked_root_ids": sorted({
            (f.get("root_id") or f"{f.get('dim')}:{f.get('name')}")
            for f in findings if f.get("blocker")
        }),
        "checkpoint_advanced": bool(advanced),
        "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def _write_cursor(ctx, findings, *, rescanned_from_durable):
    try:
        RB.write_cursor(ctx["repo"], {
            "schema_version": RB.SCHEMA_VERSION,
            "root_ids": sorted({
                (f.get("root_id") or f"{f.get('dim')}:{f.get('name')}") for f in findings
            }),
            "rescanned_from_durable": bool(rescanned_from_durable),
            "default_head": tip_sha(ctx["repo"], "refs/heads/" + ctx["default"]),
        })
    except RB.BaselineError:
        pass


def _interrupt(point):
    if os.environ.get(TEST_INTERRUPT_ENV) == point:
        raise SystemExit(99)


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
    ap.add_argument("--bootstrap", action="store_true",
                    help="create or resume the one-time adoption baseline")
    ap.add_argument("--max-passes", type=int, default=1,
                    help="maximum non-converging repair/bootstrap passes before halting (default: 1)")
    ap.add_argument("--json", action="store_true", help="emit the machine-readable JSON report")
    ap.add_argument("--check-journal-divergence", action="store_true",
                    help="run the journal-replay reconciliation dimension (opt-in until #150 "
                         "journals every sanctioned mutation door; doctor Row 10 passes it)")
    ap.add_argument("--rotate-journal", action="store_true", help="Rotate journal for terminal items")
    ap.add_argument("--ensure-gitignore", action="store_true",
                    help="idempotently add the journal's advisory-lock sidecar to the repo-root "
                         ".gitignore, then exit (scaffold/update step; append-only, non-destructive)")
    ap.add_argument("--report-session",
                    help="write THIS run's scan result (scanner_exit + clean) to the session-scoped "
                         "janitor command report so the /idc:janitor closeout can re-read it — the "
                         "honest path where the SCANNER, not the caller, records the exit code")
    ap.add_argument("--report-nonce",
                    help="bind the written janitor report to the active command record's nonce "
                         "(the closeout requires the report's nonce to match)")
    args = ap.parse_args()

    # Scaffold/update step: no board read needed — ensure the sidecar is ignored and exit.
    if args.ensure_gitignore:
        ensure_lock_gitignored(os.path.abspath(args.repo))
        sys.exit(0)

    # ROUND-5 finding 7: a ground-truth failure in build_ctx (not a git repo, no default branch,
    # `git worktree list` failed, github without owner/project, or an unreadable board) exits 2 BEFORE
    # the normal scan-report write below. Catch that exit-2 and write the nonce-bound report FIRST, so
    # the /idc:janitor closeout's `blocked_external` can re-derive the honest exit-2 from the artifact
    # the SCANNER wrote — no hand-written report. The exit code is preserved (re-raised).
    try:
        ctx = build_ctx(args)
    except SystemExit as exc:
        if exc.code == _JANITOR_BLOCKED_EXIT:
            _write_scan_report(os.path.abspath(args.repo), args.report_session, args.report_nonce,
                               _JANITOR_BLOCKED_EXIT)
        raise

    if args.rotate_journal:
        journal_path = os.path.join(ctx["repo"], JOURNAL_REL)
        rotate_journal(ctx, journal_path)
        sys.exit(0)

    def perform_scan(context):
        findings0, indeterminate0 = scan(context)
        journal_path0 = os.path.join(context["repo"], JOURNAL_REL)
        # OPT-IN until #150: sanctioned mutation doors outside the engine (adapter claim/move/close
        # prose, gate closes, recirc stage stamps) do not journal yet, so a default replay would report
        # documented normal traffic as RISKY divergence. Doctor Row 10 passes the flag explicitly.
        if args.check_journal_divergence:
            indeterminate0 = check_journal_divergence(context, findings0, journal_path0) or indeterminate0
        stubborn = os.environ.get(TEST_STUBBORN_ENV)
        if stubborn:
            findings0.append(finding(
                RISKY, "plan", stubborn, "test-only stubborn finding", "leave blocked for the next pass",
                classification="test-stubborn", root_id=stubborn, blocker=True,
            ))
        findings0 = dedupe_findings(findings0)
        plan0 = build_plan(findings0)
        if indeterminate0:
            plan0["blockers"] = sorted(set(plan0["blockers"]) | {"indeterminate-ground-truth"})
        if not plan0["validated"]:
            plan0["blockers"] = sorted(set(plan0["blockers"]) | {"unvalidated-plan"})
        return findings0, indeterminate0, plan0

    max_passes = max(1, int(args.max_passes or 1))
    rescanned = bool(ctx.get("reconciliation", {}).get("receipt")) and not bool(ctx.get("reconciliation", {}).get("cursor"))

    if args.bootstrap:
        resume = bool((ctx.get("reconciliation", {}).get("marker") or {}).get("in_progress"))
        RB.write_marker(
            ctx["repo"],
            default_branch_name=ctx["default"],
            default_branch_head=tip_sha(ctx["repo"], "refs/heads/" + ctx["default"]),
            in_progress={"mode": "bootstrap", "requested_max_passes": max_passes},
            resume={"resumed": resume},
        )
        _interrupt(BOOTSTRAP_INTERRUPT_POINT)
        previous_blockers = None
        stagnant = 0
        for pass_no in range(1, max_passes + 1):
            ctx = build_ctx(args)
            rescanned = bool(ctx.get("reconciliation", {}).get("receipt")) and not bool(ctx.get("reconciliation", {}).get("cursor"))
            findings, indeterminate, plan = perform_scan(ctx)
            plan.update({
                "passes": pass_no,
                "halted": False,
                "checkpoint_advanced": False,
                "rescanned_from_durable": rescanned,
                "resumed": resume,
            })
            _write_cursor(ctx, findings, rescanned_from_durable=rescanned)
            if plan["validated"] and not plan["blockers"]:
                receipt = _bootstrap_receipt(ctx, findings)
                checkpoint = _checkpoint_payload(findings, advanced=True)
                RB.finalize_bootstrap(ctx["repo"], receipt, checkpoint)
                ctx_done = build_ctx(args)
                rescanned_done = bool(ctx_done.get("reconciliation", {}).get("receipt")) and not bool(ctx_done.get("reconciliation", {}).get("cursor"))
                findings_done, indeterminate_done, plan_done = perform_scan(ctx_done)
                plan_done.update({
                    "passes": pass_no,
                    "halted": False,
                    "checkpoint_advanced": True,
                    "rescanned_from_durable": rescanned_done,
                    "resumed": resume,
                })
                _write_cursor(ctx_done, findings_done, rescanned_from_durable=rescanned_done)
                if args.json:
                    emit_json(findings_done, ctx_done, indeterminate_done, plan=plan_done)
                else:
                    print_report(findings_done, ctx_done)
                    print("janitor: " + _VERDICT_BANNER[verdict(findings_done, indeterminate_done)])
                code = _exit_code(findings_done, indeterminate_done)
                _write_scan_report(ctx_done["repo"], args.report_session, args.report_nonce, code)
                sys.exit(code)
            blockers = tuple(plan["blockers"])
            stagnant = (stagnant + 1) if blockers == previous_blockers else 1
            previous_blockers = blockers
            RB.write_checkpoint(ctx["repo"], _checkpoint_payload(findings, advanced=False))
            if stagnant >= max_passes:
                plan["halted"] = True
                if args.json:
                    emit_json(findings, ctx, indeterminate, plan=plan)
                else:
                    print_report(findings, ctx)
                    print("janitor: findings")
                _write_scan_report(ctx["repo"], args.report_session, args.report_nonce, 1)
                sys.exit(1)
        plan["halted"] = True
        if args.json:
            emit_json(findings, ctx, indeterminate, plan=plan)
        else:
            print_report(findings, ctx)
            print("janitor: findings")
        _write_scan_report(ctx["repo"], args.report_session, args.report_nonce, 1)
        sys.exit(1)

    findings, indeterminate, plan = perform_scan(ctx)
    plan.update({
        "passes": 1,
        "halted": False,
        "checkpoint_advanced": False,
        "rescanned_from_durable": rescanned,
        "resumed": False,
    })
    _write_cursor(ctx, findings, rescanned_from_durable=rescanned)

    if not args.apply_safe:
        if args.json:
            emit_json(findings, ctx, indeterminate, plan=plan)
        else:
            print_report(findings, ctx)
            print("janitor: " + _VERDICT_BANNER[verdict(findings, indeterminate)])
        code = _exit_code(findings, indeterminate)
        _write_scan_report(ctx["repo"], args.report_session, args.report_nonce, code)
        sys.exit(code)

    # --apply-safe: execute SAFE-FIX, re-scan, report the delta.
    if not args.json:
        print("janitor: applying SAFE-FIX tier only (RISKY + REPORT-ONLY are never touched)…")
    applied = apply_safe(findings, ctx) if plan["validated"] else []
    if not args.json:
        for (f, ok, note) in applied:
            mark = "✓" if ok else "✗"
            print(f"janitor: {mark} {f['dim']} {f['name']} — {note}")
    ctx2 = build_ctx(args)                       # re-establish ground truth after mutation
    rescanned2 = bool(ctx2.get("reconciliation", {}).get("receipt")) and not bool(ctx2.get("reconciliation", {}).get("cursor"))
    findings2, indeterminate2, plan2 = perform_scan(ctx2)
    plan2.update({
        "passes": 1,
        "halted": False,
        "checkpoint_advanced": False,
        "rescanned_from_durable": rescanned2,
        "resumed": False,
    })
    _write_cursor(ctx2, findings2, rescanned_from_durable=rescanned2)
    if args.json:
        emit_json(findings2, ctx2, indeterminate2, applied=applied, plan=plan2)
    else:
        applied_ok = sum(1 for (_f, ok, _n) in applied if ok)
        print(f"janitor: delta — {applied_ok} SAFE-FIX applied; {len(findings2)} findings remain")
        print_report(findings2, ctx2)
        v2 = verdict(findings2, indeterminate2)
        print("janitor: " + ("findings remain (RISKY/REPORT-ONLY need review)"
                             if v2 == "findings" else _VERDICT_BANNER[v2]))
    code2 = _exit_code(findings2, indeterminate2)
    _write_scan_report(ctx2["repo"], args.report_session, args.report_nonce, code2)
    sys.exit(code2)


def _exit_code(findings, indeterminate):
    return _VERDICT_EXIT[verdict(findings, indeterminate)]


def _write_scan_report(repo, session, nonce, exit_code):
    """Persist THIS scan's verdict to the session-scoped janitor command report (wave-4 finding 7): the
    /idc:janitor closeout re-reads `{scanner_exit, clean, nonce}` from it, so the SCANNER — not a
    caller integer — records the exit, bound to the active command record's nonce. BEST-EFFORT + a
    no-op without `--report-session` (a plain scan / --json consumer is unaffected)."""
    if not session:
        return
    try:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "hooks"))
        import idc_command_report as CR  # noqa: E402 — lazy (scripts/hooks on sys.path)
        CR.write_janitor_report(repo, int(exit_code), session,
                                str(nonce) if nonce else None)
    except Exception:  # noqa: BLE001 — persisting the report must never break the scan's exit contract
        pass


if __name__ == "__main__":
    # Broken-pipe guard: `--json` prints every finding, and this is the hand-run verification command
    # an operator routinely pipes to `jq`/`head`. See scripts/idc_stdio.py.
    import idc_stdio
    raise SystemExit(idc_stdio.run_guarded(main))
