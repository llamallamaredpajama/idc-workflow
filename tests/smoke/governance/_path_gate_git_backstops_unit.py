#!/usr/bin/env python3
"""Focused unit/integration coverage for IDC's Git Path Gate backstops."""
from __future__ import annotations

import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


PLUGIN_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))

import idc_git_path_gate as gate  # noqa: E402


ZERO_SHA = "0" * 40


def run_git(repo: Path, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return proc.stdout.strip()


def init_repo(repo: Path) -> None:
    repo.mkdir(parents=True)
    run_git(repo, "init", "-q")
    run_git(repo, "checkout", "-q", "-b", "main")
    run_git(repo, "config", "user.email", "idc@example.test")
    run_git(repo, "config", "user.name", "IDC Path Gate")


def commit_file(repo: Path, relpath: str, content: str, message: str) -> str:
    path = repo / relpath
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    run_git(repo, "add", "--", relpath)
    run_git(repo, "commit", "-qm", message)
    return run_git(repo, "rev-parse", "HEAD")


class GitBackstopTests(unittest.TestCase):
    def test_new_ref_collects_paths_from_every_newly_reachable_commit(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            remote = root / "remote.git"
            init_repo(repo)
            commit_file(repo, "TRACKER.md", "ticket: baseline\n", "test: baseline")
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            run_git(repo, "remote", "add", "origin", str(remote))
            run_git(repo, "push", "-qu", "origin", "main")

            run_git(repo, "checkout", "-q", "-b", "smuggled")
            commit_file(repo, "TRACKER.md", "ticket: SMUGGLED\n", "test: protected lower commit")
            tip = commit_file(repo, "src/app.ts", "export const x = 2;\n", "test: ordinary tip")

            paths = gate._collect_pre_push_paths(
                str(repo),
                [f"refs/heads/smuggled {tip} refs/heads/smuggled {ZERO_SHA}\n"],
                remote="origin",
            )

            self.assertEqual({"TRACKER.md", "src/app.ts"}, set(paths))

    def test_new_ref_rev_list_error_falls_back_to_tip(self) -> None:
        calls: list[tuple[str, ...]] = []

        def fake_run_git(_repo: str, *args: str) -> str:
            calls.append(args)
            if args and args[0] == "ls-remote":
                return ""
            if args and args[0] == "rev-list":
                raise RuntimeError("simulated rev-list failure")
            if args and args[0] == "diff-tree":
                return "src/app.ts"
            self.fail(f"unexpected git call: {args}")

        with mock.patch.object(gate, "_run_git", side_effect=fake_run_git):
            paths = gate._collect_pre_push_paths(
                "/unused",
                [f"refs/heads/topic {'a' * 40} refs/heads/topic {ZERO_SHA}\n"],
                remote="origin",
            )

        self.assertEqual(["src/app.ts"], paths)
        self.assertEqual(("ls-remote", "--refs", "origin"), calls[0])
        self.assertEqual("rev-list", calls[1][0])
        self.assertEqual(("diff-tree", "--root", "--no-commit-id", "--name-only", "-r", "a" * 40), calls[2])

    def test_new_ref_uses_server_refs_not_stale_local_remote_tracking_refs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            remote = root / "remote.git"
            init_repo(repo)
            commit_file(repo, "TRACKER.md", "ticket: baseline\n", "test: baseline")
            subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
            run_git(repo, "remote", "add", "origin", str(remote))
            run_git(repo, "push", "-qu", "origin", "main")

            run_git(repo, "checkout", "-q", "-b", "ghost-smuggled")
            lower = commit_file(repo, "TRACKER.md", "ticket: GHOST-SMUGGLED\n", "test: protected lower")
            tip = commit_file(repo, "src/app.ts", "export const x = 3;\n", "test: innocent tip")
            run_git(repo, "update-ref", "refs/remotes/origin/ghost", lower)
            self.assertNotIn("refs/heads/ghost", run_git(remote, "show-ref"))

            paths = gate._collect_pre_push_paths(
                str(repo),
                [f"refs/heads/ghost-smuggled {tip} refs/heads/ghost-smuggled {ZERO_SHA}\n"],
                remote="origin",
            )

            self.assertEqual({"TRACKER.md", "src/app.ts"}, set(paths))

    def test_new_ref_remote_query_failure_is_scrubbed_and_never_falls_back_local(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            fake_dir = Path(td)
            fake_git = fake_dir / "git"
            fake_git.write_text(
                "#!/bin/sh\n"
                "printf 'fatal: password=hunter2xyzzy while querying actual push remote\\n' >&2\n"
                "exit 1\n",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)
            path = f"{fake_dir}{os.pathsep}{os.environ.get('PATH', '')}"

            with mock.patch.dict(os.environ, {"PATH": path}):
                with self.assertRaises(RuntimeError) as raised:
                    gate._collect_pre_push_paths(
                        "/unused",
                        [f"refs/heads/topic {'a' * 40} refs/heads/topic {ZERO_SHA}\n"],
                        remote="origin",
                    )

            detail = str(raised.exception)
            self.assertNotIn("hunter2xyzzy", detail)
            self.assertIn("[REDACTED]", detail)
            self.assertIn("actual push remote", detail)

    def test_managed_pre_push_replays_stdin_and_preserves_args_and_status(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            plugin = root / "plugin"
            wrappers = plugin / "scripts" / "hooks"
            wrappers.mkdir(parents=True)
            wrapper = wrappers / "idc_git_pre_push.sh"
            wrapper.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n%s\\n' \"$2\" \"$3\" > {str(root / 'gate.args')!r}\n"
                f"cat > {str(root / 'gate.stdin')!r}\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)

            original = root / "original-pre-push"
            original.write_text(
                "#!/bin/sh\n"
                f"printf '%s\\n%s\\n' \"$1\" \"$2\" > {str(root / 'original.args')!r}\n"
                f"cat > {str(root / 'original.stdin')!r}\n"
                "exit 23\n",
                encoding="utf-8",
            )
            original.chmod(0o755)

            managed = root / "pre-push"
            managed.write_text(gate._managed_content("pre-push", str(plugin), str(original)), encoding="utf-8")
            managed.chmod(0o755)
            record = f"refs/heads/topic {'a' * 40} refs/heads/topic {ZERO_SHA}\n".encode()
            proc = subprocess.run(
                [str(managed), "origin", "/tmp/remote.git"],
                input=record,
                capture_output=True,
            )

            self.assertEqual(23, proc.returncode)
            self.assertEqual(record, (root / "gate.stdin").read_bytes())
            self.assertEqual(record, (root / "original.stdin").read_bytes())
            self.assertEqual("origin\n/tmp/remote.git\n", (root / "original.args").read_text(encoding="utf-8"))

    def test_managed_pre_push_reraises_sigterm_and_cleans_stdin_buffer(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            plugin = root / "plugin"
            wrappers = plugin / "scripts" / "hooks"
            runtime_tmp = root / "runtime-tmp"
            wrappers.mkdir(parents=True)
            runtime_tmp.mkdir()
            ready = root / "child-ready"
            wrapper = wrappers / "idc_git_pre_push.sh"
            wrapper.write_text(
                "#!/bin/sh\n"
                f"printf ready > {str(ready)!r}\n"
                "sleep 30\n",
                encoding="utf-8",
            )
            wrapper.chmod(0o755)
            managed = root / "pre-push"
            managed.write_text(gate._managed_content("pre-push", str(plugin), None), encoding="utf-8")
            managed.chmod(0o755)
            env = dict(os.environ)
            env["TMPDIR"] = str(runtime_tmp)
            proc = subprocess.Popen(
                [str(managed), "origin", "/tmp/remote.git"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                env=env,
            )
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    buffers = list(runtime_tmp.glob("idc-path-gate-pre-push.*"))
                    if ready.exists() and buffers:
                        break
                    if proc.poll() is not None:
                        self.fail(f"managed hook exited before signal: {proc.returncode}")
                    time.sleep(0.02)
                else:
                    self.fail("managed hook did not start its sleeping child and stdin buffer")

                os.killpg(proc.pid, signal.SIGTERM)
                proc.communicate(timeout=5)
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate()

            self.assertEqual(-signal.SIGTERM, proc.returncode)
            self.assertEqual([], list(runtime_tmp.iterdir()))

    def test_staged_deletion_is_collected(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            init_repo(repo)
            commit_file(repo, "TRACKER.md", "ticket: demo\n", "test: baseline")
            (repo / "TRACKER.md").unlink()
            run_git(repo, "add", "-u", "--", "TRACKER.md")

            self.assertEqual(["TRACKER.md"], gate._collect_pre_commit_paths(str(repo)))

    def test_external_hooks_path_is_refused_without_writes(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            external = root / "shared-hooks"
            init_repo(repo)
            external.mkdir()
            run_git(repo, "config", "core.hooksPath", str(external))

            with self.assertRaisesRegex(RuntimeError, "outside.*common Git directory"):
                gate.install_hooks(str(repo), str(PLUGIN_ROOT))

            self.assertEqual([], list(external.iterdir()))

    def test_linked_worktree_uses_its_own_repository_common_git_directory(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            linked = root / "linked"
            init_repo(repo)
            commit_file(repo, "README.md", "demo\n", "test: baseline")
            run_git(repo, "worktree", "add", "-q", "-b", "topic", str(linked))

            gate.install_hooks(str(linked), str(PLUGIN_ROOT))

            common = Path(run_git(linked, "rev-parse", "--git-common-dir"))
            if not common.is_absolute():
                common = linked / common
            self.assertTrue((common.resolve() / "hooks" / "pre-commit").is_file())
            self.assertTrue(gate.verify_hooks(str(linked), str(PLUGIN_ROOT))[0])

    def test_install_rolls_back_original_when_managed_replace_fails(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            init_repo(repo)
            hook = Path(run_git(repo, "rev-parse", "--git-path", "hooks/pre-commit"))
            if not hook.is_absolute():
                hook = repo / hook
            backup = Path(gate._backup_path(str(hook)))
            original = b"#!/bin/sh\necho original\n"
            hook.write_bytes(original)
            hook.chmod(0o744)
            original_mode = stat.S_IMODE(hook.stat().st_mode)
            before = set(hook.parent.iterdir())
            real_replace = os.replace

            def fail_managed_replace(src: str, dst: str) -> None:
                if Path(dst) == hook and Path(src) != backup:
                    raise OSError("simulated managed replacement failure")
                real_replace(src, dst)

            with mock.patch.object(gate.os, "replace", side_effect=fail_managed_replace):
                with self.assertRaisesRegex(OSError, "simulated managed replacement failure"):
                    gate.install_hooks(str(repo), str(PLUGIN_ROOT))

            self.assertEqual(original, hook.read_bytes())
            self.assertEqual(original_mode, stat.S_IMODE(hook.stat().st_mode))
            self.assertFalse(backup.exists())
            self.assertEqual(before, set(hook.parent.iterdir()))

    def test_install_recovers_backup_only_state_as_chained_original(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            repo = root / "repo"
            init_repo(repo)
            hook = Path(run_git(repo, "rev-parse", "--git-path", "hooks/pre-push"))
            if not hook.is_absolute():
                hook = repo / hook
            backup = Path(gate._backup_path(str(hook)))
            marker = root / "chained-ran"
            backup.write_text(f"#!/bin/sh\nprintf ran > {str(marker)!r}\n", encoding="utf-8")
            backup.chmod(0o755)

            gate.install_hooks(str(repo), str(PLUGIN_ROOT))

            self.assertEqual(str(backup), gate._parse_original(hook.read_text(encoding="utf-8")))
            subprocess.run([str(hook), "origin", "/tmp/remote.git"], cwd=repo, input=b"", check=True)
            self.assertEqual("ran", marker.read_text(encoding="utf-8"))
            self.assertEqual([], [path for path in hook.parent.iterdir() if "idc-path-gate-tmp" in path.name])

    def test_retry_completes_after_forced_second_hook_failure(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td) / "repo"
            init_repo(repo)
            pre_push = Path(run_git(repo, "rev-parse", "--git-path", "hooks/pre-push"))
            if not pre_push.is_absolute():
                pre_push = repo / pre_push
            real_replace = os.replace

            def fail_pre_push_once(src: str, dst: str) -> None:
                if Path(dst) == pre_push and "idc-path-gate-tmp" in Path(src).name:
                    raise OSError("simulated second-hook failure")
                real_replace(src, dst)

            with mock.patch.object(gate.os, "replace", side_effect=fail_pre_push_once):
                with self.assertRaisesRegex(OSError, "simulated second-hook failure"):
                    gate.install_hooks(str(repo), str(PLUGIN_ROOT))

            pre_commit = pre_push.with_name("pre-commit")
            self.assertIn(gate.MANAGED_MARKER, pre_commit.read_text(encoding="utf-8"))
            self.assertFalse(pre_push.exists())

            gate.install_hooks(str(repo), str(PLUGIN_ROOT))
            self.assertEqual((True, "ok"), gate.verify_hooks(str(repo), str(PLUGIN_ROOT)))

    def test_managed_hook_has_no_unreachable_manual_status_branch(self) -> None:
        content = gate._managed_content("pre-push", str(PLUGIN_ROOT), None)
        self.assertIn("set -eu", content)
        self.assertNotIn("rc=$?", content)


if __name__ == "__main__":
    unittest.main(verbosity=2)
