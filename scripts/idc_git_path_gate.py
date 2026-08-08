#!/usr/bin/env python3
"""Git backstops for the shared IDC Path Gate."""
from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from typing import Iterable

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

import idc_credential_shapes as CS  # noqa: E402
import idc_path_gate as PG  # noqa: E402

MANAGED_MARKER = "IDC_PATH_GATE_MANAGED=1"
ORIGINAL_PREFIX = "IDC_PATH_GATE_ORIGINAL="


def _repo_root(repo: str) -> str:
    return os.path.abspath(repo)


def _git_path(repo: str, relpath: str) -> str:
    return PG.git_path(repo, relpath)


def _hook_path(repo: str, kind: str) -> str:
    return os.path.join(_hooks_dir(repo), kind)


def _hooks_dir(repo: str) -> str:
    hooks_dir = _git_path(repo, "hooks")
    common_dir = _run_git(repo, "rev-parse", "--git-common-dir")
    if not os.path.isabs(common_dir):
        common_dir = os.path.join(repo, common_dir)
    resolved_hooks = os.path.realpath(hooks_dir)
    resolved_common = os.path.realpath(common_dir)
    try:
        owned = os.path.commonpath((resolved_common, resolved_hooks)) == resolved_common
    except ValueError:
        owned = False
    if not owned:
        raise RuntimeError(
            f"refusing hooks directory outside repository common Git directory: {hooks_dir}"
        )
    return hooks_dir


def _backup_path(hook_path: str) -> str:
    return hook_path + ".idc-path-gate-original"


def _managed_content(kind: str, plugin_root: str, original_hook: str | None) -> str:
    wrapper = os.path.join(plugin_root, "scripts", "hooks", f"idc_git_{kind.replace('-', '_')}.sh")
    original = original_hook or ""
    header = (
        "#!/bin/sh\n"
        f"# {MANAGED_MARKER}\n"
        f"# IDC_PATH_GATE_KIND={kind}\n"
        f"# {ORIGINAL_PREFIX}{original}\n"
        "set -eu\n"
        f"PLUGIN_ROOT={shlex.quote(plugin_root)}\n"
        f"IDC_ORIGINAL_HOOK={shlex.quote(original)}\n"
    )
    if kind == "pre-push":
        return (
            f"{header}"
            "IDC_PUSH_STDIN=$(mktemp \"${TMPDIR:-/tmp}/idc-path-gate-pre-push.XXXXXX\")\n"
            "idc_cleanup() { rm -f \"$IDC_PUSH_STDIN\"; }\n"
            "idc_reraise() {\n"
            "  IDC_SIGNAL=$1\n"
            "  trap - 0 \"$IDC_SIGNAL\"\n"
            "  idc_cleanup\n"
            "  kill -s \"$IDC_SIGNAL\" \"$$\"\n"
            "}\n"
            "trap 'idc_reraise HUP' HUP\n"
            "trap 'idc_reraise INT' INT\n"
            "trap 'idc_reraise TERM' TERM\n"
            "trap idc_cleanup 0\n"
            "cat > \"$IDC_PUSH_STDIN\"\n"
            f"sh {shlex.quote(wrapper)} \"$PLUGIN_ROOT\" \"$@\" < \"$IDC_PUSH_STDIN\"\n"
            "if [ -n \"$IDC_ORIGINAL_HOOK\" ] && [ -x \"$IDC_ORIGINAL_HOOK\" ]; then\n"
            "  \"$IDC_ORIGINAL_HOOK\" \"$@\" < \"$IDC_PUSH_STDIN\"\n"
            "fi\n"
            "exit 0\n"
        )
    return (
        f"{header}"
        f"sh {shlex.quote(wrapper)} \"$PLUGIN_ROOT\" \"$@\"\n"
        "if [ -n \"$IDC_ORIGINAL_HOOK\" ] && [ -x \"$IDC_ORIGINAL_HOOK\" ]; then\n"
        "  exec \"$IDC_ORIGINAL_HOOK\" \"$@\"\n"
        "fi\n"
        "exit 0\n"
    )


def _write_text(path: str, content: str) -> None:
    parent = os.path.dirname(path)
    os.makedirs(parent, exist_ok=True)
    fd, temp_path = tempfile.mkstemp(
        dir=parent,
        prefix=f".{os.path.basename(path)}.idc-path-gate-tmp-",
        text=True,
    )
    try:
        fh = os.fdopen(fd, "w", encoding="utf-8")
        fd = -1
        with fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.chmod(temp_path, 0o755)
        os.replace(temp_path, path)
    finally:
        if fd >= 0:
            os.close(fd)
        if os.path.exists(temp_path):
            os.unlink(temp_path)


def _read_text(path: str) -> str:
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _parse_original(content: str) -> str:
    for line in content.splitlines():
        if line.startswith(f"# {ORIGINAL_PREFIX}"):
            return line[len(f"# {ORIGINAL_PREFIX}") :]
    return ""


def install_hooks(repo: str, plugin_root: str) -> None:
    """Install atomically per hook; retry completes a recoverable partial pair.

    If the second hook fails, the first may already be managed. That state is intentional: the
    original error propagates unchanged, and a later call safely retries the missing second hook.
    """
    repo = _repo_root(repo)
    plugin_root = os.path.abspath(plugin_root)
    for kind in ("pre-commit", "pre-push"):
        hook = _hook_path(repo, kind)
        backup = _backup_path(hook)
        original = ""
        moved_original = False
        original_mode: int | None = None
        try:
            if os.path.exists(hook):
                try:
                    existing = _read_text(hook)
                except OSError:
                    existing = ""
                if MANAGED_MARKER in existing:
                    original = _parse_original(existing)
                else:
                    if os.path.exists(backup):
                        raise RuntimeError(
                            f"refusing to overwrite unmanaged {kind} hook while backup already exists: {hook}"
                        )
                    original_mode = stat.S_IMODE(os.stat(hook).st_mode)
                    os.replace(hook, backup)
                    moved_original = True
                    os.chmod(backup, os.stat(backup).st_mode | stat.S_IXUSR)
                    original = backup
            elif os.path.exists(backup):
                os.chmod(backup, os.stat(backup).st_mode | stat.S_IXUSR)
                original = backup
            content = _managed_content(kind, plugin_root, original)
            _write_text(hook, content)
        except Exception as exc:
            if moved_original and not os.path.exists(hook) and os.path.exists(backup):
                try:
                    os.replace(backup, hook)
                    if original_mode is not None:
                        os.chmod(hook, original_mode)
                except OSError as rollback_exc:
                    raise RuntimeError(
                        f"failed to install {kind} hook and restore its original: {rollback_exc}"
                    ) from exc
            raise


def verify_hooks(repo: str, plugin_root: str) -> tuple[bool, str]:
    repo = _repo_root(repo)
    plugin_root = os.path.abspath(plugin_root)
    for kind in ("pre-commit", "pre-push"):
        hook = _hook_path(repo, kind)
        if not os.path.isfile(hook):
            return False, f"missing {kind} hook at {hook}"
        if not os.access(hook, os.X_OK):
            return False, f"missing executable bit on {kind} hook at {hook}"
        try:
            current = _read_text(hook)
        except OSError as exc:
            return False, f"cannot read {kind} hook: {exc}"
        if MANAGED_MARKER not in current:
            return False, f"{kind} hook is not IDC-managed"
        original = _parse_original(current)
        expected = _managed_content(kind, plugin_root, original)
        if current != expected:
            return False, f"{kind} hook diverged from the IDC-managed content"
        if original and not os.path.exists(original):
            return False, f"{kind} hook references a missing chained original hook: {original}"
        if original and not os.access(original, os.X_OK):
            return False, f"{kind} chained original hook is not executable: {original}"
    return True, "ok"


def _run_git(repo: str, *args: str) -> str:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(CS.scrub(proc.stderr or proc.stdout or "git failed").strip())
    return (proc.stdout or "").strip()


def _collect_pre_commit_paths(repo: str) -> list[str]:
    out = _run_git(repo, "diff", "--cached", "--name-only", "--diff-filter=ACDMRTUXB")
    return [line.strip() for line in out.splitlines() if line.strip()]


def _remote_ref_shas(repo: str, remote: str) -> list[str]:
    if not remote:
        raise RuntimeError("actual push remote is required to inspect a new ref")
    out = _run_git(repo, "ls-remote", "--refs", remote)
    shas: list[str] = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 2 or not re.fullmatch(r"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})", parts[0]):
            raise RuntimeError("git ls-remote returned an invalid server ref record")
        shas.append(parts[0])
    return shas


def _collect_pre_push_commits(
    repo: str,
    lines: Iterable[str],
    *,
    remote: str | None = None,
) -> list[tuple[str, list[str]]]:
    """Every outgoing commit paired with the paths IT touches, in push order.

    Attribution is per commit, not a flattened union, because a path's admissibility can depend on
    WHICH commit carries it: the sanctioned uninstall removal commit may delete a protected machine
    surface, while the identical path in any other commit may not (issue #201)."""
    commits: list[tuple[str, list[str]]] = []
    seen_commits: set[str] = set()
    server_shas: list[str] | None = None
    for line in lines:
        parts = line.strip().split()
        if len(parts) != 4:
            continue
        _, local_sha, _, remote_sha = parts
        if not local_sha or re.fullmatch(r"0+", local_sha):
            continue
        if remote_sha and not re.fullmatch(r"0+", remote_sha):
            exclusions = [remote_sha]
        else:
            if server_shas is None:
                server_shas = _remote_ref_shas(repo, remote or "")
            exclusions = server_shas
        try:
            reachable = _run_git(repo, "rev-list", local_sha, "--not", *exclusions).splitlines()
        except RuntimeError:
            reachable = [local_sha]
        for commit in reachable:
            commit = commit.strip()
            if not commit or commit in seen_commits:
                continue
            seen_commits.add(commit)
            out = _run_git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit)
            commits.append((commit, [rel.strip() for rel in out.splitlines() if rel.strip()]))
    return commits


def _collect_pre_push_paths(
    repo: str,
    lines: Iterable[str],
    *,
    remote: str | None = None,
) -> list[str]:
    """Flattened, de-duplicated outgoing paths — the full unexempted set."""
    paths: list[str] = []
    seen: set[str] = set()
    for _, rels in _collect_pre_push_commits(repo, lines, remote=remote):
        for rel in rels:
            if rel not in seen:
                seen.add(rel)
                paths.append(rel)
    return paths


# ── the uninstall push door (issue #201) ─────────────────────────────────────────────────────────
# `/idc:uninstall` must land its removal as ONE revertable commit, and that commit necessarily
# DELETES protected machine surfaces (`TRACKER.md`, the install receipt) alongside the governance
# anchor. The commit itself is admissible when it is made — both backstops are already dormant by
# then, because the anchor has left the worktree. But the pre-push backstop re-examines the whole
# OUTGOING RANGE under TODAY's posture, so the moment the repo is governed again (a fresh
# `/idc:init`, a `git revert`) that historical deletion is re-litigated and the push is refused
# forever, poisoning every later commit in the range.
#
# The door that resolves it binds to evidence, never to a commit message. Two INDEPENDENT checks must
# both hold before a commit's protected deletions are exempted:
#   1. a sanctioned door recorded the commit's own OID in the machine-owned witness, and
#   2. the gate re-derives the commit's shape from git AT PUSH TIME and confirms it.
# Check 2 is what makes the witness un-forgeable in practice: hand-editing the witness file buys
# nothing, because the shape is re-proven from the object database on every push.


def _commit_name_status(repo: str, commit: str) -> list[tuple[str, str]]:
    """(status, path) for every path the commit touches; a rename/copy yields BOTH endpoints."""
    out = _run_git(
        repo, "diff-tree", "--root", "--no-commit-id", "--name-status", "-r", "-z", commit
    )
    fields = [field for field in out.split("\0") if field != ""]
    records: list[tuple[str, str]] = []
    index = 0
    while index < len(fields):
        status = fields[index]
        index += 1
        # Rename/copy records carry two paths; every other status carries one.
        arity = 2 if status[:1] in {"R", "C"} else 1
        for _ in range(arity):
            if index >= len(fields):
                break
            records.append((status[:1], fields[index]))
            index += 1
    return records


def _tree_has(repo: str, commit: str, relpath: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", repo, "cat-file", "-e", f"{commit}:{relpath}"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0


def uninstall_commit_problem(repo: str, commit: str) -> str | None:
    """None when `commit` has the sanctioned uninstall shape, else why it does not.

    THE SHAPE, re-derived from git every time and never read from any caller-supplied claim:
      * it resolves to exactly one commit with exactly ONE parent (a merge is not an uninstall);
      * its parent's tree HAS the governance anchor and its own tree does NOT — it is the commit that
        carries the repository out of IDC governance;
      * every protected machine surface it touches is touched by DELETION ONLY. Without this clause
        "delete the anchor" would be a universal key for writing machine-owned state in the same
        commit."""
    try:
        oid = _run_git(repo, "rev-parse", "--verify", "--quiet", f"{commit}^{{commit}}")
    except RuntimeError as exc:
        return f"`{commit}` does not resolve to a commit in this repository ({exc})"
    if not oid:
        return f"`{commit}` does not resolve to a commit in this repository"

    parents = _run_git(repo, "rev-list", "--parents", "-n", "1", oid).split()[1:]
    if len(parents) != 1:
        return (
            f"commit {oid} has {len(parents)} parent(s); the uninstall removal commit is a single "
            "ordinary commit on top of the governed history"
        )
    parent = parents[0]

    if not _tree_has(repo, parent, PG.GOVERNANCE_ANCHOR_RELPATH):
        return (
            f"commit {oid} is not the ungoverning commit: its parent does not carry the governance "
            f"anchor `{PG.GOVERNANCE_ANCHOR_RELPATH}`, so this commit cannot be the one that removes it"
        )
    if _tree_has(repo, oid, PG.GOVERNANCE_ANCHOR_RELPATH):
        return (
            f"commit {oid} is not the ungoverning commit: it leaves the governance anchor "
            f"`{PG.GOVERNANCE_ANCHOR_RELPATH}` in place, so the repository stays IDC-governed"
        )

    for status, rel in _commit_name_status(repo, oid):
        if PG.is_protected_machine_surface(rel) and status != "D":
            return (
                f"commit {oid} does not only REMOVE machine-owned state: it applies `{status}` to the "
                f"protected surface `{rel}`"
            )
    return None


def _exempt_witnessed_uninstall_paths(
    repo: str, commits: list[tuple[str, list[str]]]
) -> list[str]:
    """Flatten the outgoing commits into the gated path set, dropping ONLY the protected deletions of
    commits that are both witnessed and still shape-verified.

    Everything else in an exempted commit — its ordinary paths — stays in the gated set and is still
    judged against the live authorization boundary, so the exemption removes exactly the part no
    authorization could ever cover and nothing more."""
    witnessed = PG.read_uninstall_witness(repo)
    paths: list[str] = []
    seen: set[str] = set()
    for commit, rels in commits:
        exempt: set[str] = set()
        if commit.lower() in witnessed and uninstall_commit_problem(repo, commit) is None:
            exempt = {rel for rel in rels if PG.is_protected_machine_surface(rel)}
        for rel in rels:
            if rel in exempt or rel in seen:
                continue
            seen.add(rel)
            paths.append(rel)
    return paths


def _gate(repo: str, plugin_root: str, action: str, paths: list[str]) -> dict[str, object]:
    # V-AUTH stage 3: echo the live authorization's ticket/graph-node identity into the request —
    # the shared gate now REQUIRES it. This backstop is Codex's per-tool coverage path (Codex runs no
    # per-tool hook), so the echo here is what keeps sanctioned Codex commits/pushes admissible
    # under the identity-required gate.
    request: dict[str, object] = {"action": action, "paths": paths}
    request.update(PG.request_identity(_repo_root(repo)))
    return PG.evaluate_request(_repo_root(repo), plugin_root, request)


def _gate_exit(decision: dict[str, object]) -> int:
    observe = decision.get("observe")
    if isinstance(observe, str) and observe:
        print(f"IDC Path Gate observe (would deny): {observe}", file=sys.stderr)
    if decision.get("allowed"):
        return 0
    print(str(decision.get("reason") or "IDC Path Gate denied the git mutation"), file=sys.stderr)
    return 1


def cmd_install(args: argparse.Namespace) -> int:
    install_hooks(args.repo, args.plugin_root)
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    ok, detail = verify_hooks(args.repo, args.plugin_root)
    if ok:
        return 0
    print(f"IDC Path Gate git hook verification failed: {detail}", file=sys.stderr)
    return 2


def cmd_pre_commit(args: argparse.Namespace) -> int:
    repo = _repo_root(args.repo)
    paths = _collect_pre_commit_paths(repo)
    if not paths:
        return 0
    return _gate_exit(_gate(repo, args.plugin_root, "git", paths))


def cmd_pre_push(args: argparse.Namespace) -> int:
    repo = _repo_root(args.repo)
    commits = _collect_pre_push_commits(repo, sys.stdin.read().splitlines(), remote=args.remote)
    paths = _exempt_witnessed_uninstall_paths(repo, commits)
    if not paths:
        return 0
    return _gate_exit(_gate(repo, args.plugin_root, "git", paths))


def cmd_witness_uninstall(args: argparse.Namespace) -> int:
    """The sanctioned uninstall push door: prove the shape, then record the commit.

    Called by `/idc:uninstall` Phase 3c right after it lands the removal commit, and by an operator
    recovering a repository that an older plugin version already stranded. It is safe to point at any
    commit: anything that is not the ungoverning shape is refused here AND, independently, at push."""
    repo = _repo_root(args.repo)
    problem = uninstall_commit_problem(repo, args.commit)
    if problem:
        print(
            "IDC Path Gate refused to witness this commit as an IDC uninstall removal: " + problem,
            file=sys.stderr,
        )
        return 1
    oid = _run_git(repo, "rev-parse", "--verify", f"{args.commit}^{{commit}}")
    PG.record_uninstall_commit(repo, oid)
    print(f"IDC Path Gate: witnessed uninstall removal commit {oid}; it is now publishable.")
    return 0


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="op", required=True)

    p = sub.add_parser("install-hooks")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_install)

    p = sub.add_parser("verify-hooks")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_verify)

    p = sub.add_parser("pre-commit")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.set_defaults(func=cmd_pre_commit)

    p = sub.add_parser("pre-push")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", required=True)
    p.add_argument("--remote")
    p.set_defaults(func=cmd_pre_push)

    p = sub.add_parser(
        "witness-uninstall",
        help="record an IDC uninstall removal commit so it can be pushed (shape-verified)",
    )
    p.add_argument("--repo", required=True)
    p.add_argument("--commit", required=True)
    p.set_defaults(func=cmd_witness_uninstall)

    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:  # noqa: BLE001
        print(f"IDC Path Gate git helper failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
