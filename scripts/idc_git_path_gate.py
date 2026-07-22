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


def _collect_pre_push_paths(
    repo: str,
    lines: Iterable[str],
    *,
    remote: str | None = None,
) -> list[str]:
    paths: list[str] = []
    seen: set[str] = set()
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
            commits = _run_git(repo, "rev-list", local_sha, "--not", *exclusions).splitlines()
        except RuntimeError:
            commits = [local_sha]
        outputs = [
            _run_git(repo, "diff-tree", "--root", "--no-commit-id", "--name-only", "-r", commit)
            for commit in commits
            if commit.strip()
        ]
        for out in outputs:
            for rel in out.splitlines():
                rel = rel.strip()
                if rel and rel not in seen:
                    seen.add(rel)
                    paths.append(rel)
    return paths


def _gate(repo: str, plugin_root: str, action: str, paths: list[str]) -> dict[str, object]:
    return PG.evaluate_request(_repo_root(repo), plugin_root, {"action": action, "paths": paths})


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
    paths = _collect_pre_push_paths(repo, sys.stdin.read().splitlines(), remote=args.remote)
    if not paths:
        return 0
    return _gate_exit(_gate(repo, args.plugin_root, "git", paths))


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
