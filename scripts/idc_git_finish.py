#!/usr/bin/env python3
"""idc_git_finish.py — the finisher's deterministic git-finalization tail (design §B.1, RC1/RC2/RC3).

The audit (`docs/dev/audit-2026-07-01-idc-effectiveness.md` §3) found the finisher's post-merge
cleanup is prose an agent is trusted to follow, with nothing verifying the result: 18 production
sessions hit "cannot delete branch … used by worktree" because the worktree-removal half of the
doctrine was skipped (RC1); 17/139 merges omitted `--delete-branch` outright (RC2); the tracker
`close` is two non-atomic calls whose second half silently dropped 10 times (RC3). This helper
replaces those five prose steps with ONE deterministic, fail-closed call: remove the worktree FIRST
(so the branch is no longer checked out anywhere), merge with `--delete-branch`, explicitly verify
the remote branch is actually gone (`git ls-remote` — the audit proved the flag alone is not
sufficient on these repos), delete the local branch, close the tracker (both halves) through the
active backend, then re-verify the full end state before ever printing success.

Backend-blind by construction (`idc:idc-tracker-adapter`'s `close` op — Status→Done + issue-close):
reads `docs/workflow/tracker-config.yaml::backend` and dispatches to the matching implementation
itself (filesystem via the sibling `idc_tracker_fs.py`; github via `gh` directly, resolving a
SINGLE issue's project item through its own `issue.projectItems` GraphQL field rather than a
whole-board read — no dependency on any other helper's board reader). It performs its own read-back
end-state verify, so it is correct standalone.

Fail-closed: every step is verified; the FIRST one that cannot be confirmed prints
`finish: <step> failed: <detail>` to stderr and exits 1 — a dropped step can never pass silently.
The janitor (`scripts/idc_git_janitor.py`) is the reconciler for whatever a dead session still
leaves behind; this helper is prevention, not the safety net.

Usage: idc_git_finish.py --pr N --issue M --worktree PATH [--repo DIR] [--tracker PATH]
  exit 0  every step verified — prints `finish: ok`.
  exit 1  the first unverifiable step — prints `finish: <step> failed: <detail>` to stderr.

CLOSE-ONLY recovery (`--close-only`): an ALREADY-MERGED PR whose board was never advanced — the
phantom-idle `synthesized-complete` shape (v4 Phase 3 Stage E4). The normal `gh pr merge` step would
hard-fail on a merged PR, so this mode SKIPS the merge (and the verdict receipt gate); the proven
MERGED state (`verify_pr_merged`) IS the receipt, then the SAME fail-closed cleanup + tracker-close
tail runs. Idempotent — safe to re-run when the item is already Done / branch already gone. Prints
`finish: ok (close-only)`.
"""
import argparse
import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)
import idc_review_verdict_check as VC   # noqa: E402 — the verdict validator + PASSING set (reuse)
import idc_transition as TE             # noqa: E402 — load_verdict + unmet_merge_conditions (reuse)
import idc_file_findings as FF          # noqa: E402 — work_items + existing-keys readers (reuse)
import idc_gh_board                     # noqa: E402 — BoardReadError for fail-closed github routing

REMOTE = "origin"
MERGE_METHODS = ("squash", "merge", "rebase")

# Branch → item resolution for the close-only OWNERSHIP accident-guard (reviewer P2-1 + P2-A). An
# INDEPENDENT copy of idc_teammate_idle_synth._resolve_ref_item, kept local per this helper's
# established doctrine of owning its parsers with no cross-unit import dependency (see read_backend/
# read_config below). IDC build branches (`worktree-build-<n>` / `impl-<n>` / `<n>-slug`) put the item
# number as a standalone token that Stage D's STRICT leading-segment regex would miss. Resolve
# UNAMBIGUOUSLY (P2-A — an ambiguous head must not close some unrelated item): a supported SHAPE wins,
# else exactly ONE standalone number, else None (fail closed). The proven MERGED PR state is the real
# receipt; this is only a cheap guard against a mis-aimed --issue.
_STRICT_ITEM_RE = re.compile(r"(?:^|/)(?:issue-)?(\d+)(?:[-_]|$)")     # Stage D strict leading-segment
_ADAPTER_ITEM_RE = re.compile(r"(?:^|/)(?:worktree-)?(?:build|impl|unit|fix|issue)-(\d+)$")  # adapter shape
_ITEM_TOKEN_RE = re.compile(r"(?:^|[-_/])(\d+)(?=$|[-_/])")            # any standalone numeric token


def _resolve_branch_item(branch):
    """(item_number_or_None, all_standalone_numbers) — unambiguous linkage only (see the header). The
    ADAPTER shape is consulted FIRST (round-8 micro-fix): consulting the strict leading-segment regex
    first let a date/parent PREFIX win via the `or` short-circuit (`2026-07/worktree-build-42` → 2026),
    which could accept a WRONG item. The end-anchored adapter unit shape is authoritative → its number
    wins over a strict prefix; a --issue that is not that unit is refused (no wrong close)."""
    branch = branch or ""
    nums = sorted({int(m.group(1)) for m in _ITEM_TOKEN_RE.finditer(branch)})
    m = _ADAPTER_ITEM_RE.search(branch) or _STRICT_ITEM_RE.search(branch)
    if m:
        return int(m.group(1)), nums
    if len(nums) == 1:
        return nums[0], nums
    return None, nums

# Resolves ONE issue's project-item id + board Status + open/closed state in a single GraphQL call —
# O(1) per issue via the issue's own `projectItems` field, never a whole-board read (the exact
# quadratic shape RC4 flags elsewhere in this fix package).
ISSUE_PROJECT_QUERY = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    issue(number:$number){
      state
      projectItems(first:20){
        nodes{
          id
          project{ number }
          fieldValueByName(name:"Status"){
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}
"""


def _fail(step, detail, code=1):
    """code=1 (default): a genuine verified-failure finding (the audited git/tracker state doesn't
    hold — matches the sibling helpers' convention, e.g. idc_acceptance_check.py's `gap` exit 1).
    code=2: a usage/config error caught before any mutation was attempted."""
    sys.stderr.write(f"finish: {step} failed: {detail}\n")
    sys.exit(code)


def _warn(msg):
    """A NON-fatal note to stderr (does not exit) — used by the close-only live-remote-tip guard to
    record a SKIPPED (never destroyed) remote branch while the close continues."""
    sys.stderr.write(f"finish: {msg}\n")


def _run(cmd, cwd):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    except OSError as e:
        return 1, "", str(e)
    return p.returncode, p.stdout, p.stderr


# ── tracker-config.yaml (grep/sed parse — the repo's no-yq convention; mirrors
#    idc_recirc_sweep.read_backend/read_config, kept as an independent copy so this helper has no
#    logic dependency on the recirc sweep or any other unit's owned file) ─────────────────────────
def read_backend(repo):
    cfg = os.path.join(repo, "docs", "workflow", "tracker-config.yaml")
    if not os.path.isfile(cfg):
        return None
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^\s*backend:\s*([A-Za-z0-9_-]+)", line)
                if m:
                    return m.group(1).strip()
    except OSError:
        return None
    return None


def read_config(repo):
    cfg = os.path.join(repo, "docs", "workflow", "tracker-config.yaml")
    project_number, field_ids, in_fields = "", {}, False
    try:
        with open(cfg, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r'^project_number:\s*"?([^"#\n]*)"?', line)
                if m:
                    project_number = m.group(1).strip()
                if re.match(r"^field_ids:\s*$", line):
                    in_fields = True
                    continue
                if in_fields:
                    fm = re.match(r"^\s+([A-Za-z]+):\s*\"?([^\"#\n]*)\"?", line)
                    if fm:
                        field_ids[fm.group(1)] = fm.group(2).strip()
                    elif re.match(r"^\S", line):
                        in_fields = False
    except OSError:
        pass
    return project_number, field_ids


# ── PR / branch mechanics ───────────────────────────────────────────────────────────────────────
def resolve_branch(repo, pr):
    rc, out, err = _run(["gh", "pr", "view", str(pr), "--json", "headRefName", "-q", ".headRefName"], repo)
    if rc != 0 or not out.strip():
        _fail("resolve-branch", f"could not resolve PR #{pr}'s head branch: {err.strip()[:200] or out.strip()}")
    return out.strip()


def pr_merge(repo, pr, merge_method):
    rc, out, err = _run(["gh", "pr", "merge", str(pr), f"--{merge_method}", "--delete-branch"], repo)
    if rc != 0:
        _fail("merge", f"gh pr merge --{merge_method} --delete-branch #{pr} failed: {err.strip()[:300]}")


def push_delete_remote_best_effort(repo, branch):
    """Best-effort delete of the remote branch (close-only recovery only). A normal finish deletes it
    via `gh pr merge --delete-branch`; in close-only that merge already happened out-of-band, so if the
    branch LINGERS (merged without the flag) we delete it here so the recovery is idempotent. NEVER
    fails: an already-gone ref is the success case — `verify_remote_branch_gone` is the real check."""
    _run(["git", "push", REMOTE, "--delete", branch], repo)


def verify_pr_merged(repo, pr):
    rc, out, err = _run(["gh", "pr", "view", str(pr), "--json", "state", "-q", ".state"], repo)
    if rc != 0:
        _fail("verify-pr-merged", f"could not read PR #{pr} state: {err.strip()[:200]}")
    if out.strip() != "MERGED":
        _fail("verify-pr-merged", f"PR #{pr} state is {out.strip()!r}, expected MERGED")


# ── head-branch containment (close-only P1): a MERGED PR state only proves the OLD tip merged; a
#    branch ADVANCED or REUSED since carries NEW unmerged commits that a delete would drop. Before ANY
#    destructive step, require the head ref's CURRENT tip to still be contained in base. Small local
#    git primitives per this helper's own no-cross-unit doctrine (mirrors idc_teammate_idle_synth). ──
def _git_out(repo, *args):
    rc, out, err = _run(["git", *args], repo)
    return out.strip() if rc == 0 and out.strip() else None


def _resolve_committish(repo, ref):
    """<ref>'s commit sha, or None if the ref does not resolve (absent/deleted)."""
    return _git_out(repo, "rev-parse", "--verify", "--quiet", ref + "^{commit}")


def _is_ancestor(repo, commit, base):
    rc, _o, _e = _run(["git", "merge-base", "--is-ancestor", commit, base], repo)
    return rc == 0


def _patch_id(repo, diff_argv):
    """Stable patch-id of a diff, or None (empty diff / failure)."""
    try:
        d = subprocess.run(["git", *diff_argv], cwd=repo, capture_output=True, text=True, timeout=15)
        if d.returncode != 0 or not d.stdout:
            return None
        p = subprocess.run(["git", "patch-id", "--stable"], cwd=repo,
                           input=d.stdout, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    if p.returncode != 0:
        return None
    toks = p.stdout.split()
    return toks[0] if toks else None


def _aggregate_landed(repo, ref, base, cap=200):
    """True iff the ref's AGGREGATE diff (all commits since the merge-base, as one patch) is
    patch-equivalent to a single commit already in base — the multi-commit-squash containment case."""
    mb = _git_out(repo, "merge-base", base, ref)
    if not mb:
        return False
    branch_pid = _patch_id(repo, ["diff", mb, ref])
    if not branch_pid:
        return False
    log = _git_out(repo, "log", "--format=%H", mb + ".." + base)
    if not log:
        return False
    for i, commit in enumerate(log.splitlines()):
        if i >= cap:
            break
        if _patch_id(repo, ["diff-tree", "-p", commit]) == branch_pid:
            return True
    return False


def _cherry_all_landed(repo, ref, base):
    """True iff EVERY commit the ref is ahead of base is patch-equivalent to a commit already in base
    (`git cherry <base> <ref>` reports only `-` lines) — the per-commit rebase / cherry-pick landing.
    Mirrors the synth's per-commit `git cherry` completeness (codex P2-1) so the containment gate never
    refuses a rebase-landed branch the synth already steered as synthesized-complete."""
    out = _git_out(repo, "cherry", base, ref)
    if out is None:
        return False
    lines = [ln for ln in out.splitlines() if ln.strip()]
    return bool(lines) and not any(ln.startswith("+") for ln in lines)


def pr_base_ref(repo, pr):
    """The PR's base branch name via gh (best-effort — None if unavailable, callers fall back)."""
    rc, out, err = _run(["gh", "pr", "view", str(pr), "--json", "baseRefName", "-q", ".baseRefName"], repo)
    return out.strip() if rc == 0 and out.strip() else None


def _containment_bases(repo, pr):
    """Ordered, deduped base committishes to verify head containment against: the PR's baseRefName (+
    its remote-tracking form), then origin/HEAD's target and local/remote main/master — every one that
    resolves. Mirrors the synth's base-candidate list so a fetch-no-ff / unpushed-merge shape is safe."""
    prbase = pr_base_ref(repo, pr)
    raw = [prbase, f"{REMOTE}/{prbase}" if prbase else None, "main", "master"]
    sym = _git_out(repo, "symbolic-ref", "refs/remotes/origin/HEAD")
    if sym and sym.startswith("refs/remotes/"):
        raw.append(sym[len("refs/remotes/"):])
    raw += [f"{REMOTE}/main", f"{REMOTE}/master"]
    seen, out = set(), []
    for cand in raw:
        if not cand or cand in seen:
            continue
        seen.add(cand)
        if _resolve_committish(repo, cand):
            out.append(cand)
    return out


def _contained_in_any_base(repo, ref_or_sha, bases):
    """True iff <ref_or_sha> is fully landed in SOME base candidate — ancestor of, all-commits
    patch-equivalent to (per-commit rebase/cherry-pick), or aggregate patch-equivalent to (squash) a
    commit in, that base. The single containment predicate shared by the local-tip refuse gate and the
    live-remote-tip delete guard (git accepts a raw sha as a committish for merge-base/cherry/diff)."""
    return any(_is_ancestor(repo, ref_or_sha, b) or _cherry_all_landed(repo, ref_or_sha, b)
               or _aggregate_landed(repo, ref_or_sha, b) for b in bases)


def refuse_if_head_advanced(repo, branch, pr):
    """Fail closed if the head branch's CURRENT tip (local `branch` OR remote-tracking `origin/branch`)
    still EXISTS and is NOT contained in base — ancestor of, or aggregate patch-equivalent to a commit
    in, some base candidate (codex P1). A MERGED PR only proves the OLD tip merged; deleting an advanced
    /reused branch drops its new unmerged commits. A deleted/absent ref has nothing to drop → skipped."""
    bases = _containment_bases(repo, pr)
    for ref in (branch, f"{REMOTE}/{branch}"):
        tip = _resolve_committish(repo, ref)
        if tip is None:
            continue  # this ref is gone — nothing to delete for it
        if not bases:
            _fail("close-only-advanced",
                  f"head branch '{ref}' still exists but no base ref could be resolved to verify it is "
                  "merged — refusing to delete/close (resolve base / re-finish)")
        if _contained_in_any_base(repo, tip, bases):
            continue  # tip fully landed in some authoritative base (ff / per-commit / squash) — safe
        n = _git_out(repo, "rev-list", "--count", bases[0] + ".." + ref)
        ahead = int(n) if (n and n.isdigit()) else 0
        _fail("close-only-advanced",
              f"head branch '{ref}' has advanced past the merged PR #{pr} ({ahead} unmerged "
              "commit(s)) — refusing to delete/close; resume or re-finish the new work")


def live_remote_tip_deletable(repo, branch, pr):
    """True iff the LIVE remote tip of <branch> is SAFE to delete — its exact sha is locally KNOWN and
    CONTAINED in base (codex round-8 P1, DATA-SAFETY). The remote-tracking ref that refuse_if_head_advanced
    checked can be STALE (someone pushed since the last fetch), so a destructive `push --delete` must
    verify the LIVE tip via `git ls-remote`, not origin/<branch>. Absent on the remote ⇒ nothing to
    delete ⇒ True. ls-remote failure / a live tip unknown locally / an advanced (uncontained) live tip
    ⇒ False + warn: SKIP the delete, leave the branch (it resurfaces as in-flight on a later synth pass
    once fetched) — never silently destroy live advanced work. The close still completes (the merged-PR
    receipt holds); only the remote delete is skipped."""
    rc, out, err = _run(["git", "ls-remote", REMOTE, "refs/heads/" + branch], repo)
    if rc != 0:
        _warn(f"close-only: live remote tip of '{branch}' unreadable (git ls-remote rc={rc}) — leaving "
              "the remote branch (it resurfaces via the idle synth after a fetch)")
        return False
    line = out.strip()
    if not line:
        return True  # not present on the remote — nothing to delete
    live = line.split()[0]
    if _resolve_committish(repo, live) is None:
        _warn(f"close-only: live remote tip {live[:12]} of '{branch}' is unknown locally (the remote "
              "advanced since the last fetch) — leaving the remote branch (it resurfaces via the idle "
              "synth after a fetch)")
        return False
    bases = _containment_bases(repo, pr)
    if bases and _contained_in_any_base(repo, live, bases):
        return True
    _warn(f"close-only: live remote tip {live[:12]} of '{branch}' is not proven contained in base — "
          "leaving the remote branch (it resurfaces via the idle synth after a fetch)")
    return False


def verify_remote_branch_gone(repo, branch):
    rc, out, err = _run(["git", "ls-remote", "--heads", REMOTE, branch], repo)
    if rc != 0:
        _fail("verify-remote-branch", f"git ls-remote --heads {REMOTE} {branch} failed: {err.strip()[:200]}")
    if out.strip():
        _fail("verify-remote-branch",
              f"remote branch '{branch}' still exists on {REMOTE} after --delete-branch "
              f"(the flag alone is not sufficient on this repo): {out.strip()[:200]}")


def branch_delete_local(repo, branch):
    rc, _out, err = _run(["git", "branch", "-D", branch], repo)
    if rc != 0 and "not found" not in err.lower():
        _fail("branch-delete-local", f"git branch -D {branch} failed: {err.strip()[:200]}")


def verify_local_branch_gone(repo, branch):
    rc, out, err = _run(["git", "branch", "--list", branch], repo)
    if rc != 0:
        _fail("verify-local-branch", f"git branch --list {branch} failed: {err.strip()[:200]}")
    if out.strip():
        _fail("verify-local-branch", f"local branch '{branch}' still exists: {out.strip()}")


# ── worktree mechanics ──────────────────────────────────────────────────────────────────────────
def git_worktree_list(repo):
    rc, out, err = _run(["git", "worktree", "list", "--porcelain"], repo)
    if rc != 0:
        _fail("worktree-remove", f"git worktree list --porcelain failed: {err.strip()[:200]}")
    return [line[len("worktree "):].strip() for line in out.splitlines() if line.startswith("worktree ")]


def worktree_for_branch(repo, branch):
    """The path of the worktree that currently has <branch> checked out, or None. Parses
    `git worktree list --porcelain` (worktree/branch record pairs). Used by close-only recovery: a
    branch still checked out in the idle teammate's worktree would make `git branch -D` fail, so the
    finisher removes that worktree first (codex P2b). Best-effort: a list failure returns None."""
    rc, out, err = _run(["git", "worktree", "list", "--porcelain"], repo)
    if rc != 0:
        return None
    cur = None
    for line in out.splitlines():
        if line.startswith("worktree "):
            cur = line[len("worktree "):].strip()
        elif line.startswith("branch "):
            ref = line[len("branch "):].strip()
            name = ref[len("refs/heads/"):] if ref.startswith("refs/heads/") else ref
            if name == branch:
                return cur
    return None


def worktree_remove(repo, worktree_abs):
    registered = git_worktree_list(repo)
    is_registered = any(os.path.realpath(p) == os.path.realpath(worktree_abs) for p in registered)
    if not os.path.isdir(worktree_abs) and not is_registered:
        return  # idempotent: already gone
    rc, _out, err = _run(["git", "worktree", "remove", worktree_abs], repo)
    if rc != 0:
        _fail("worktree-remove", f"git worktree remove {worktree_abs} failed: {err.strip()[:300]}")


def verify_worktree_gone(repo, worktree_abs):
    if os.path.isdir(worktree_abs):
        _fail("verify-worktree-gone", f"worktree directory still exists: {worktree_abs}")
    registered = git_worktree_list(repo)
    if any(os.path.realpath(p) == os.path.realpath(worktree_abs) for p in registered):
        _fail("verify-worktree-gone", f"worktree still registered in `git worktree list`: {worktree_abs}")


# ── tracker close (backend-blind — the adapter's `close` op: Status->Done + issue close) ─────────
def gh_owner_name(repo):
    rc, out, err = _run(["gh", "repo", "view", "--json", "owner,name",
                          "--jq", '.owner.login + " " + .name'], repo)
    if rc != 0 or not out.strip():
        _fail("tracker-close", f"could not resolve repo owner/name: {err.strip()[:200]}")
    parts = out.strip().split(" ", 1)
    if len(parts) != 2:
        _fail("tracker-close", f"unexpected `gh repo view` output: {out!r}")
    return parts[0], parts[1]


def gh_issue_project_status(repo, owner, name, number, project_number, step):
    rc, out, err = _run(["gh", "api", "graphql",
                          "-f", f"query={ISSUE_PROJECT_QUERY}",
                          "-f", f"owner={owner}", "-f", f"name={name}",
                          "-F", f"number={number}"], repo)
    if rc != 0:
        _fail(step, f"graphql issue/project read for #{number} failed: {err.strip()[:200]}")
    try:
        issue = json.loads(out)["data"]["repository"]["issue"]
    except (json.JSONDecodeError, KeyError, TypeError):
        _fail(step, f"unparseable graphql response for #{number}: {out[:200]}")
    item = None
    for node in (issue.get("projectItems") or {}).get("nodes") or []:
        if (node.get("project") or {}).get("number") == project_number:
            item = node
            break
    status_name = None
    if item:
        fv = item.get("fieldValueByName") or {}
        status_name = fv.get("name")
    item_id = item.get("id") if item else None
    return issue.get("state"), status_name, item_id


def github_close(repo, issue, project_number_str, field_ids, owner, name):
    try:
        project_number = int(project_number_str)
    except (TypeError, ValueError):
        _fail("tracker-close", f"tracker-config.yaml project_number is not a valid integer: {project_number_str!r}")
    _state, _status, item_id = gh_issue_project_status(repo, owner, name, issue, project_number, "tracker-close")
    if not item_id:
        _fail("tracker-close", f"issue #{issue} is not on project #{project_number} (empty item id) — refusing to mutate")
    status_fid = field_ids.get("Status")
    if not status_fid:
        _fail("tracker-close", "tracker-config.yaml field_ids.Status is not cached")
    rc, out, err = _run(["gh", "project", "field-list", str(project_number), "--owner", owner,
                          "--format", "json", "--jq",
                          '.fields[] | select(.name=="Status") | .options[] | select(.name=="Done") | .id'],
                         repo)
    if rc != 0 or not out.strip():
        _fail("tracker-close", f"could not resolve Status=Done option id: {err.strip()[:200] or 'empty result'}")
    option_id = out.strip()
    rc, out, err = _run(["gh", "project", "view", str(project_number), "--owner", owner,
                          "--format", "json", "--jq", ".id"], repo)
    if rc != 0 or not out.strip():
        _fail("tracker-close", f"could not resolve project node id: {err.strip()[:200] or 'empty result'}")
    project_node = out.strip()
    rc, _out, err = _run(["gh", "project", "item-edit", "--id", item_id, "--project-id", project_node,
                           "--field-id", status_fid, "--single-select-option-id", option_id], repo)
    if rc != 0:
        _fail("tracker-close", f"Status->Done item-edit failed: {err.strip()[:200]}")
    rc, _out, err = _run(["gh", "issue", "close", str(issue)], repo)
    if rc != 0:
        _fail("tracker-close", f"gh issue close #{issue} failed: {err.strip()[:200]}")


def verify_github_closed(repo, issue, project_number_str, owner, name):
    project_number = int(project_number_str)
    state, status, _item_id = gh_issue_project_status(repo, owner, name, issue, project_number, "verify-tracker-closed")
    if state != "CLOSED":
        _fail("verify-tracker-closed", f"issue #{issue} state is {state!r}, expected CLOSED")
    if status != "Done":
        _fail("verify-tracker-closed", f"issue #{issue} board Status is {status!r}, expected Done")


def filesystem_close(tracker_path, issue):
    rc, _out, err = _run(["python3", os.path.join(SCRIPT_DIR, "idc_tracker_fs.py"),
                           "--tracker", tracker_path, "close", "--num", str(issue)], ".")
    if rc != 0:
        _fail("tracker-close", f"filesystem close of #{issue} failed: {err.strip()[:200]}")


def verify_filesystem_closed(tracker_path, issue):
    rc, out, err = _run(["python3", os.path.join(SCRIPT_DIR, "idc_tracker_fs.py"),
                          "--tracker", tracker_path, "show", "--num", str(issue), "--field", "Status"], ".")
    if rc != 0:
        _fail("verify-tracker-closed", f"could not read back tracker #{issue} Status: {err.strip()[:200]}")
    if out.strip() != "Done":
        _fail("verify-tracker-closed", f"tracker issue #{issue} Status is {out.strip()!r}, expected Done")


def tracker_close(backend, repo, issue, tracker_path, project_number, field_ids, owner, name,
                  verdict_path=None):
    if backend == "filesystem":
        filesystem_close(tracker_path, issue)
    else:
        github_close(repo, issue, project_number, field_ids, owner, name)
    # The finisher is a sanctioned close door, so its close must land in the SAME canonical
    # transition journal the engine writes — otherwise replay reconciliation reports every normally
    # finished item as a false journal↔board divergence. Best-effort like every journal_append: the
    # close above already happened, a journal failure must not fail the finish.
    tracker_rel = os.path.relpath(tracker_path, repo) if backend == "filesystem" else None
    TE.journal_append(repo, "close", backend, tracker_rel,
                      {"num": issue, "to_status": "Done", "verdict": verdict_path,
                       "agent": "finisher"})


def verify_tracker_closed(backend, repo, issue, tracker_path, project_number, owner, name):
    if backend == "filesystem":
        verify_filesystem_closed(tracker_path, issue)
    else:
        verify_github_closed(repo, issue, project_number, owner, name)


# ── receipt gate: routed findings + merge_conditions (v4 Phase 2, plan §3.3) ─────────────────────
# The finish tail is the SECOND write door that closes an item (the transition engine's guarded
# `close` op is the first). So it must enforce the SAME receipt invariant the engine does, or it is a
# hole: a PR whose review left nits stranded as prose, or one carrying an unmet pre-merge condition
# (the silently-downgraded #246->#248 class), could still be merged+closed here. This gate runs
# BEFORE any mutation (worktree remove / merge / tracker close); the FIRST unmet check refuses the
# whole finish. Every check REUSES an existing function — the verdict validator, the filer's
# key/existing-keys readers, and the engine's unmet_merge_conditions — no second implementation.
def routing_gap(verdict, backend, repo, tracker_path, owner, project):
    """The routable findings (each minor/nit finding + every deferral — exactly what the filer's
    idc_file_findings.work_items derives) whose stable dedupe `key` is NOT yet among the board's filed
    idc-recirc-source keys. [] ⇒ every routable finding is already routed to the board. Raises
    idc_gh_board.BoardReadError (github, unreadable board) so the caller fails CLOSED — never confirm
    routing (and merge) on an unverifiable board state."""
    items = FF.work_items(verdict)
    if not items:
        return []  # a clean PASS (no nits/deferrals) has nothing to route
    if backend == "filesystem":
        existing = FF._fs_existing_keys(tracker_path)
    else:
        existing = FF._github_existing_keys(repo, owner, project)  # raises BoardReadError → fail-closed
    return [it for it in items if it["key"] not in existing]


def enforce_receipt_gate(args, backend, repo, tracker_path, owner, project_number):
    """Refuse the finish unless the review verdict for this PR/issue is valid, passing, owns the item,
    has every routable finding routed to the board (unless --no-require-routed-findings), and has no
    unmet merge_conditions. Fail-closed: the first unmet check prints `finish: <step> failed` and
    exits 1, BEFORE any worktree/merge/tracker mutation."""
    if not args.verdict:
        _fail("verdict", "the finish is a receipt gate: --verdict <path> (the review verdict for this "
                         "PR/issue) is required — refusing to merge/close without the review receipt")
    try:
        verdict = TE.load_verdict(args.verdict)  # reuse: validates via idc_review_verdict_check.check
    except TE.TransitionError as e:
        _fail("verdict", str(e).replace("close denied: ", ""))
    disposition = verdict.get("verdict")
    if disposition not in VC.PASSING:
        _fail("verdict", f"disposition {disposition!r} is not passing — only {sorted(VC.PASSING)} may "
                         "finish (a FAIL/FAIL-BLOCKED must be fixed, not merged)")
    if verdict.get("issue") != args.issue:
        _fail("verdict", f"verdict is for issue #{verdict.get('issue')}, not the finishing item "
                         f"#{args.issue} — the receipt must own the item it closes")
    if verdict.get("pr") != args.pr:
        _fail("verdict", f"verdict is for PR #{verdict.get('pr')}, not the finishing PR #{args.pr}")
    if args.require_routed:
        try:
            gap = routing_gap(verdict, backend, repo, tracker_path, owner, project_number)
        except idc_gh_board.BoardReadError as e:
            _fail("require-routed-findings",
                  f"cannot read the board to confirm finding routing ({str(e)[:160]}) — refusing to "
                  "merge on an unverifiable routing state (re-run once the board is readable)")
        if gap:
            keys = ", ".join(it["key"] for it in gap)
            _fail("require-routed-findings",
                  f"{len(gap)} review finding(s) not yet routed to the board [{keys}] — run "
                  f"`idc_file_findings.py --repo {repo} --verdict {args.verdict}` to file them as "
                  "Recirculation items, then retry (never merge with findings stranded as reviewer prose)")
    unmet = TE.unmet_merge_conditions(verdict)  # reuse: the engine's close-guard helper
    if unmet:
        ids = ", ".join(str(c.get("id", "?")) for c in unmet)
        _fail("merge-conditions-met",
              f"{len(unmet)} merge_condition(s) unmet [{ids}] — the reviewer set a pre-merge condition "
              "that is not satisfied; refusing to merge (resolve it, re-review, retry)")


def close_only_recover(args, repo, worktree_abs, tracker_path, backend, project_number, field_ids, owner, name):
    """CLOSE-ONLY recovery for an ALREADY-MERGED PR whose board was never advanced — the phantom-idle
    `synthesized-complete` shape (v4 Phase 3 Stage E4 / codex P2). The normal finish runs `gh pr merge`,
    which HARD-FAILS on an already-merged PR, so this mode SKIPS the merge. Its RECEIPT is the provable
    MERGED STATE itself (`verify_pr_merged` — the merge already happened out-of-band, so re-gating it
    with the review verdict is both meaningless and impossible for a teammate that went idle; the merged
    state is a STRONGER receipt than a verdict — the code is demonstrably in base). It then runs the
    SAME fail-closed cleanup + tracker-close tail as the normal path, and is IDEMPOTENT: safe to re-run
    when the item is already Done / the branch already deleted / the worktree already gone.

    NOTE this deliberately does NOT run `enforce_receipt_gate` (the verdict receipt) — that gate exists
    to authorize a MERGE, and there is no merge here. It is a new, narrow RECOVERY door; the default
    finish path and its receipt gate are untouched. But it MUST still PROVE OWNERSHIP before mutating
    the board (codex P1b): the merged PR's head branch must link to --issue via Stage D's
    branch-number convention — else a merged PR for a DIFFERENT item could close the wrong board item."""
    branch = resolve_branch(repo, args.pr)
    verify_pr_merged(repo, args.pr)   # THE RECEIPT: the PR must actually be MERGED (else refuse)

    # OWNERSHIP ACCIDENT-GUARD (P1b + P2-1 + P2-A): the proven MERGED PR state is the real receipt;
    # this is a cheap guard against a mis-aimed --issue. The head branch must resolve UNAMBIGUOUSLY to
    # --issue (a supported shape, else a single standalone number); an ambiguous or mismatched head
    # fails closed — never close a stranger's item on an unrelated / ambiguous merged PR.
    linked, nums = _resolve_branch_item(branch)
    if linked != args.issue:
        _fail("close-only-ownership",
              f"PR #{args.pr} head {branch!r} resolves to item {linked} (standalone numbers "
              f"{nums or 'none'}) not --issue {args.issue} — refusing to close (close-only requires "
              "the merged PR to own the item it closes)")

    # CONTAINMENT GATE (P1): a MERGED PR only proves the OLD tip merged. If the head branch still exists
    # and has ADVANCED / been REUSED since (new commits not in base), deleting it drops unmerged work —
    # fail closed BEFORE any worktree/branch deletion.
    refuse_if_head_advanced(repo, branch, args.pr)

    # Explicit --worktree override first (idempotent), THEN auto-detect a worktree still on this branch
    # (the idle teammate's) so `git branch -D` won't fail on a checked-out branch (P2b). Safe to remove:
    # the branch is PROVEN merged + ownership-verified.
    if worktree_abs is not None:
        worktree_remove(repo, worktree_abs)
    auto_wt = worktree_for_branch(repo, branch)
    if auto_wt is not None:
        worktree_remove(repo, auto_wt)
        verify_worktree_gone(repo, auto_wt)

    # LIVE-REMOTE-TIP data-safety (round-8 P1): only delete the remote branch when its LIVE tip (not the
    # possibly-stale remote-tracking ref) is proven contained in base. Otherwise SKIP the delete + warn
    # and continue — an advanced remote branch resurfaces as in-flight on a later synth pass, never
    # silently destroyed. Local deletion stays under refuse_if_head_advanced's local containment rule.
    if live_remote_tip_deletable(repo, branch, args.pr):
        push_delete_remote_best_effort(repo, branch)   # idempotent — a squash-merge may have left it
        verify_remote_branch_gone(repo, branch)
    branch_delete_local(repo, branch)
    tracker_close(backend, repo, args.issue, tracker_path, project_number, field_ids, owner, name)

    # Final end-state verify (same belt-and-suspenders as the normal path).
    verify_pr_merged(repo, args.pr)
    verify_local_branch_gone(repo, branch)
    if worktree_abs is not None:
        verify_worktree_gone(repo, worktree_abs)
    verify_tracker_closed(backend, repo, args.issue, tracker_path, project_number, owner, name)

    print("finish: ok (close-only)")
    sys.exit(0)


def main():
    ap = argparse.ArgumentParser(
        description="The finisher's deterministic git-finalization tail: remove the worktree, "
                    "merge + delete-branch, verify the remote branch is gone, delete the local "
                    "branch, close the tracker (backend-blind), and re-verify the full end state.")
    ap.add_argument("--pr", type=int, required=True, help="the merged triplet's PR number")
    ap.add_argument("--issue", type=int, required=True, help="the tracker issue number to close")
    ap.add_argument("--worktree", default=None,
                     help="path to the build worktree to remove (required for a normal finish; optional "
                          "in --close-only, where a phantom-idle item's worktree may already be gone)")
    ap.add_argument("--close-only", dest="close_only", action="store_true",
                     help="RECOVERY mode for an ALREADY-MERGED PR whose board was never advanced (the "
                          "phantom-idle synthesized-complete shape). SKIPS the merge (and the verdict "
                          "receipt gate — the merged PR state IS the receipt), VERIFIES the PR is really "
                          "MERGED, then runs the normal cleanup + tracker-close tail. Idempotent.")
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    ap.add_argument("--tracker", default=None,
                     help="filesystem TRACKER.md path (default: <repo>/TRACKER.md; ignored on github)")
    ap.add_argument("--merge-method", dest="merge_method", default="squash", choices=MERGE_METHODS,
                     help="gh pr merge method (default: squash) — pick the method the repo allows")
    ap.add_argument("--verdict", default=None,
                     help="path to the review verdict JSON (the finish RECEIPT) — validated + its "
                          "findings must be routed to the board + its merge_conditions met before any "
                          "merge/close. Required: the finish is a receipt gate.")
    ap.add_argument("--no-require-routed-findings", dest="require_routed", action="store_false",
                     help="escape hatch (debug only): skip the routed-findings sub-check; the verdict "
                          "is still validated, must own the item, and its merge_conditions still enforced")
    ap.set_defaults(require_routed=True)
    args = ap.parse_args()

    if not args.close_only and not args.worktree:
        ap.error("--worktree is required for a normal finish (optional only in --close-only mode)")

    repo = os.path.abspath(args.repo)
    worktree_abs = None
    if args.worktree:
        worktree_abs = args.worktree if os.path.isabs(args.worktree) else os.path.join(repo, args.worktree)
    tracker_path = args.tracker or os.path.join(repo, "TRACKER.md")

    backend = read_backend(repo)
    if backend not in ("filesystem", "github"):
        _fail("resolve-backend", f"unknown or unset backend {backend!r} in tracker-config.yaml", code=2)
    project_number, field_ids = read_config(repo) if backend == "github" else ("", {})
    owner, name = gh_owner_name(repo) if backend == "github" else (None, None)

    # CLOSE-ONLY recovery (already-merged PR, board never advanced) branches BEFORE the merge-authorizing
    # receipt gate: its receipt is the proven merged state, not the verdict — see close_only_recover.
    if args.close_only:
        close_only_recover(args, repo, worktree_abs, tracker_path, backend,
                           project_number, field_ids, owner, name)

    # RECEIPT GATE — refuse before ANY mutation if the review verdict isn't a clean, routed, condition-
    # met receipt for THIS PR/issue (the finish is a P5 receipt gate; mirrors the engine's close guard).
    enforce_receipt_gate(args, backend, repo, tracker_path, owner, project_number)

    branch = resolve_branch(repo, args.pr)
    worktree_remove(repo, worktree_abs)
    pr_merge(repo, args.pr, args.merge_method)
    verify_remote_branch_gone(repo, branch)
    branch_delete_local(repo, branch)
    tracker_close(backend, repo, args.issue, tracker_path, project_number, field_ids, owner, name,
                  verdict_path=args.verdict)

    # Final end-state verify — re-checks everything but the remote-branch state (already proven
    # right after the merge, above, with nothing in between that could touch a remote ref) before
    # ever printing success — belt-and-suspenders, catching anything that regressed between steps.
    verify_pr_merged(repo, args.pr)
    verify_local_branch_gone(repo, branch)
    verify_worktree_gone(repo, worktree_abs)
    verify_tracker_closed(backend, repo, args.issue, tracker_path, project_number, owner, name)

    print("finish: ok")
    sys.exit(0)


if __name__ == "__main__":
    main()
