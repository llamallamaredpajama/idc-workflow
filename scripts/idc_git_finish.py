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
"""
import argparse
import json
import os
import re
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REMOTE = "origin"
MERGE_METHODS = ("squash", "merge", "rebase")

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


def verify_pr_merged(repo, pr):
    rc, out, err = _run(["gh", "pr", "view", str(pr), "--json", "state", "-q", ".state"], repo)
    if rc != 0:
        _fail("verify-pr-merged", f"could not read PR #{pr} state: {err.strip()[:200]}")
    if out.strip() != "MERGED":
        _fail("verify-pr-merged", f"PR #{pr} state is {out.strip()!r}, expected MERGED")


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


def tracker_close(backend, repo, issue, tracker_path, project_number, field_ids, owner, name):
    if backend == "filesystem":
        filesystem_close(tracker_path, issue)
    else:
        github_close(repo, issue, project_number, field_ids, owner, name)


def verify_tracker_closed(backend, repo, issue, tracker_path, project_number, owner, name):
    if backend == "filesystem":
        verify_filesystem_closed(tracker_path, issue)
    else:
        verify_github_closed(repo, issue, project_number, owner, name)


def main():
    ap = argparse.ArgumentParser(
        description="The finisher's deterministic git-finalization tail: remove the worktree, "
                    "merge + delete-branch, verify the remote branch is gone, delete the local "
                    "branch, close the tracker (backend-blind), and re-verify the full end state.")
    ap.add_argument("--pr", type=int, required=True, help="the merged triplet's PR number")
    ap.add_argument("--issue", type=int, required=True, help="the tracker issue number to close")
    ap.add_argument("--worktree", required=True, help="path to the build worktree to remove")
    ap.add_argument("--repo", default=".", help="repo root (default: cwd)")
    ap.add_argument("--tracker", default=None,
                     help="filesystem TRACKER.md path (default: <repo>/TRACKER.md; ignored on github)")
    ap.add_argument("--merge-method", dest="merge_method", default="squash", choices=MERGE_METHODS,
                     help="gh pr merge method (default: squash) — pick the method the repo allows")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    worktree_abs = args.worktree if os.path.isabs(args.worktree) else os.path.join(repo, args.worktree)
    tracker_path = args.tracker or os.path.join(repo, "TRACKER.md")

    backend = read_backend(repo)
    if backend not in ("filesystem", "github"):
        _fail("resolve-backend", f"unknown or unset backend {backend!r} in tracker-config.yaml", code=2)
    project_number, field_ids = read_config(repo) if backend == "github" else ("", {})
    owner, name = gh_owner_name(repo) if backend == "github" else (None, None)

    branch = resolve_branch(repo, args.pr)
    worktree_remove(repo, worktree_abs)
    pr_merge(repo, args.pr, args.merge_method)
    verify_remote_branch_gone(repo, branch)
    branch_delete_local(repo, branch)
    tracker_close(backend, repo, args.issue, tracker_path, project_number, field_ids, owner, name)

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
