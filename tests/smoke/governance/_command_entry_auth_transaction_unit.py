#!/usr/bin/env python3
"""Focused regression coverage for command-entry registration/auth transactions."""
from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


PLUGIN_ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(PLUGIN_ROOT / "scripts"))
sys.path.insert(0, str(PLUGIN_ROOT / "scripts" / "hooks"))

import idc_command_entry_gate as gate  # noqa: E402
import idc_ledger as ledger  # noqa: E402


PLUGIN_VERSION = json.loads(
    (PLUGIN_ROOT / ".claude-plugin" / "plugin.json").read_text(encoding="utf-8")
)["version"]
FAKE_SECRET = "ghp_ABCDEFGHIJKLMNOP012345"


def _wait_for(path: Path, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.exists():
            return True
        time.sleep(0.01)
    return path.exists()


def _run_race_child(role: str, repo: str, sync_dir: str) -> None:
    """One real process in the A/B admission-lock regression."""
    sync = Path(sync_dir)
    real_write = gate.PG.write_authorization

    if role == "A":
        def coordinated_write(*args: object, **kwargs: object) -> dict:
            (sync / "a-at-auth").touch()
            # Without cross-process admission serialization, B registers and reaches auth here. With
            # the lock, B cannot register yet, so A times out briefly and authorizes its own nonce.
            _wait_for(sync / "b-at-auth", 1.0)
            auth = real_write(*args, **kwargs)
            (sync / "a-auth-done").touch()
            return auth

        side_effect = coordinated_write
        args_text = "#101"
    else:
        def fail_after_a(*_args: object, **_kwargs: object) -> None:
            (sync / "b-at-auth").touch()
            if not _wait_for(sync / "a-auth-done", 5.0):
                raise RuntimeError("A did not finish authorization")
            raise RuntimeError("simulated B authorization failure")

        side_effect = fail_after_a
        args_text = "#202"

    payload = {
        "session_id": "S-ab",
        "cwd": repo,
        "hook_event_name": "UserPromptExpansion",
        "expansion_type": "command",
        "command_name": "idc:build",
        "command_args": args_text,
        "command_source": "plugin",
        "prompt": f"/idc:build {args_text}",
    }
    with (
        mock.patch.object(gate.PG, "write_authorization", side_effect=side_effect),
        mock.patch.dict(os.environ, {"IDC_HOOKS_OBSERVE_ONLY": "0"}),
    ):
        gate._admit(payload, str(PLUGIN_ROOT), "build")


class CommandEntryAuthorizationTransactionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name) / "repo"
        (self.repo / "docs" / "workflow").mkdir(parents=True)
        (self.repo / "docs" / "workflow" / "tracker-config.yaml").write_text(
            "backend: filesystem\n", encoding="utf-8"
        )
        (self.repo / "docs" / "workflow" / "install-receipt.yaml").write_text(
            f"receipt_version: 2\nplugin_version: {PLUGIN_VERSION}\n", encoding="utf-8"
        )
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)

    def _active(self, session: str | None = None) -> list[dict]:
        return ledger.active_commands(str(self.repo), session)

    def _auth_path(self) -> Path:
        return Path(gate.PG.auth_path(str(self.repo)))

    def _open(
        self,
        session: str,
        command: str,
        nonce: str,
        *,
        build_requested: list[str] | None = None,
    ) -> dict:
        record = ledger.command_start(
            str(self.repo),
            session,
            command,
            PLUGIN_VERSION,
            "prior-args-digest",
            "fixture",
            nonce=nonce,
            build_requested=build_requested,
        )
        self.assertIsInstance(record, dict)
        return record

    def _invoke(
        self,
        *,
        session: str,
        args: str = "#101",
        observe_only: bool = False,
        auth_side_effect: object | None = None,
    ) -> tuple[int | None, str, str, mock.Mock]:
        payload = {
            "session_id": session,
            "cwd": str(self.repo),
            "hook_event_name": "UserPromptExpansion",
            "expansion_type": "command",
            "command_name": "idc:build",
            "command_args": args,
            "command_source": "plugin",
            "prompt": f"/idc:build {args}",
        }
        stdout = io.StringIO()
        stderr = io.StringIO()
        failure = auth_side_effect or RuntimeError(
            f"simulated authorization failure: token={FAKE_SECRET}"
        )
        with (
            mock.patch.object(gate.PG, "write_authorization", side_effect=failure) as auth_write,
            mock.patch.dict(
                os.environ,
                {"IDC_HOOKS_OBSERVE_ONLY": "1" if observe_only else "0"},
            ),
            redirect_stdout(stdout),
            redirect_stderr(stderr),
        ):
            try:
                gate._admit(payload, str(PLUGIN_ROOT), "build")
            except SystemExit as exc:
                code = exc.code
            else:  # pragma: no cover - every entry decision exits through the hook protocol
                code = None
        return code, stdout.getvalue(), stderr.getvalue(), auth_write

    def test_new_record_is_rolled_back_and_failure_detail_is_scrubbed(self) -> None:
        prior_other = self._open("S-new", "think", "other-command-nonce")
        prior_foreign = self._open(
            "S-foreign", "build", "foreign-session-nonce", build_requested=["#900"]
        )

        code, stdout, stderr, auth_write = self._invoke(session="S-new")

        self.assertEqual(0, code)
        self.assertEqual(1, auth_write.call_count)
        self.assertIn('"decision": "block"', stdout)
        self.assertFalse(
            any(r.get("session_id") == "S-new" and r.get("command") == "build"
                for r in self._active())
        )
        self.assertIn(prior_other, self._active())
        self.assertIn(prior_foreign, self._active())
        self.assertIn("RuntimeError", stderr)
        self.assertIn("simulated authorization failure", stderr)
        self.assertIn("[REDACTED]", stderr)
        self.assertNotIn(FAKE_SECRET, stderr)

    def test_preexisting_record_is_restored_instead_of_erased(self) -> None:
        prior = self._open(
            "S-prior", "build", "prior-build-nonce", build_requested=["#7"]
        )

        code, stdout, _stderr, _auth_write = self._invoke(session="S-prior", args="#7")

        self.assertEqual(0, code)
        self.assertIn('"decision": "block"', stdout)
        self.assertEqual([prior], self._active("S-prior"))

    def test_two_process_admissions_leave_the_admitted_record_and_auth_coherent(self) -> None:
        sync = Path(self.tmp.name) / "sync"
        sync.mkdir()
        child = str(Path(__file__).resolve())
        env = dict(os.environ)
        env["IDC_HOOKS_OBSERVE_ONLY"] = "0"
        proc_a = subprocess.Popen(
            [sys.executable, child, "--race-child", "A", str(self.repo), str(sync)],
            cwd=str(PLUGIN_ROOT),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: proc_a.poll() is None and proc_a.kill())
        self.assertTrue(_wait_for(sync / "a-at-auth", 5.0), "A never reached authorization")
        proc_b = subprocess.Popen(
            [sys.executable, child, "--race-child", "B", str(self.repo), str(sync)],
            cwd=str(PLUGIN_ROOT),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(lambda: proc_b.poll() is None and proc_b.kill())

        stdout_a, stderr_a = proc_a.communicate(timeout=10)
        stdout_b, stderr_b = proc_b.communicate(timeout=10)

        self.assertEqual(0, proc_a.returncode, stderr_a)
        self.assertEqual(0, proc_b.returncode, stderr_b)
        self.assertIn("additionalContext", stdout_a)
        self.assertIn('"decision": "block"', stdout_b)
        active = self._active("S-ab")
        self.assertEqual(1, len(active))
        self.assertEqual(["101"], active[0].get("build_requested"))
        auth_state, auth = gate.PG._read_authorization(str(self.repo))
        self.assertEqual("ok", auth_state)
        self.assertIsInstance(auth, dict)
        self.assertEqual(active[0].get("nonce"), auth.get("nonce"))

    def test_reused_failure_restores_prior_authorization_exactly(self) -> None:
        prior = self._open(
            "S-auth-prior", "build", "prior-auth-nonce", build_requested=["#31"]
        )
        gate.PG.write_authorization(
            str(self.repo), session="S-auth-prior", command="build"
        )
        prior_auth = self._auth_path().read_bytes()
        real_write = gate.PG.write_authorization

        def write_then_fail(*args: object, **kwargs: object) -> None:
            real_write(*args, **kwargs)
            raise RuntimeError("simulated failure after authorization replace")

        code, stdout, _stderr, _auth_write = self._invoke(
            session="S-auth-prior", args="#32", auth_side_effect=write_then_fail
        )

        self.assertEqual(0, code)
        self.assertIn('"decision": "block"', stdout)
        self.assertEqual([prior], self._active("S-auth-prior"))
        self.assertEqual(prior_auth, self._auth_path().read_bytes())

    def test_authorization_refuses_an_expected_nonce_that_is_no_longer_current(self) -> None:
        self._open(
            "S-auth-nonce", "build", "current-auth-nonce", build_requested=["#33"]
        )

        caught: Exception | None = None
        try:
            gate.PG.write_authorization(
                str(self.repo),
                session="S-auth-nonce",
                command="build",
                expected_nonce="superseded-auth-nonce",
            )
        except Exception as exc:  # the assertions below pin the required failure class/detail
            caught = exc

        self.assertIsInstance(caught, RuntimeError)
        self.assertIn("no longer current", str(caught))
        self.assertFalse(self._auth_path().exists())

    def test_new_failure_removes_authorization_written_before_raise(self) -> None:
        real_write = gate.PG.write_authorization

        def write_then_fail(*args: object, **kwargs: object) -> None:
            real_write(*args, **kwargs)
            raise RuntimeError("simulated failure after new authorization write")

        code, stdout, _stderr, _auth_write = self._invoke(
            session="S-auth-new", auth_side_effect=write_then_fail
        )

        self.assertEqual(0, code)
        self.assertIn('"decision": "block"', stdout)
        self.assertFalse(self._active("S-auth-new"))
        self.assertFalse(self._auth_path().exists())

    def test_pre_registration_race_restores_the_record_actually_replaced(self) -> None:
        prior = self._open(
            "S-pre-race", "build", "prior-race-nonce", build_requested=["#1"]
        )
        concurrent: dict[str, object] = {}
        real_register_start = gate.C.register_start

        def concurrent_then_register(*args: object, **kwargs: object) -> dict:
            concurrent.update(
                self._open(
                    "S-pre-race",
                    "build",
                    "concurrent-race-nonce",
                    build_requested=["#2"],
                )
            )
            return real_register_start(*args, **kwargs)

        with mock.patch.object(
            gate.C, "register_start", side_effect=concurrent_then_register
        ) as registration:
            code, stdout, _stderr, _auth_write = self._invoke(
                session="S-pre-race", args="#3"
            )

        self.assertEqual(0, code)
        self.assertEqual(1, registration.call_count)
        self.assertIn('"decision": "block"', stdout)
        self.assertNotEqual(prior, concurrent)
        self.assertEqual([concurrent], self._active("S-pre-race"))

    def test_rollback_nonce_does_not_remove_a_concurrent_replacement(self) -> None:
        replacement: dict[str, object] = {}

        def replace_then_fail(*_args: object, **_kwargs: object) -> None:
            replacement.update(
                self._open(
                    "S-race", "build", "concurrent-build-nonce", build_requested=["#202"]
                )
            )
            raise RuntimeError("simulated concurrent authorization failure")

        code, stdout, _stderr, _auth_write = self._invoke(
            session="S-race", auth_side_effect=replace_then_fail
        )

        self.assertEqual(0, code)
        self.assertIn('"decision": "block"', stdout)
        self.assertEqual([replacement], self._active("S-race"))

    def test_observe_only_allows_only_after_cleaning_new_record(self) -> None:
        code, stdout, stderr, _auth_write = self._invoke(
            session="S-observe", observe_only=True
        )

        self.assertEqual(0, code)
        self.assertEqual("", stdout)
        self.assertIn("OBSERVE-ONLY", stderr)
        self.assertFalse(self._active("S-observe"))

    def test_rollback_persistence_failure_warns_and_still_blocks(self) -> None:
        with mock.patch.object(
            gate.L, "rollback_command_start", return_value=False, create=True
        ) as rollback:
            code, stdout, stderr, _auth_write = self._invoke(session="S-rollback-fail")

        self.assertEqual(0, code)
        self.assertEqual(1, rollback.call_count)
        self.assertIn('"decision": "block"', stdout)
        self.assertIn("rollback", stderr.lower())
        self.assertIn("did not persist", stderr.lower())

    def test_authorization_rollback_failure_warns_and_still_blocks(self) -> None:
        prior = self._open(
            "S-auth-restore-fail",
            "build",
            "prior-auth-restore-nonce",
            build_requested=["#41"],
        )
        gate.PG.write_authorization(
            str(self.repo), session="S-auth-restore-fail", command="build"
        )
        real_write = gate.PG.write_authorization

        def write_then_fail(*args: object, **kwargs: object) -> None:
            real_write(*args, **kwargs)
            raise RuntimeError("simulated authorization replacement failure")

        with mock.patch.object(
            gate, "_restore_path_gate_auth", return_value=False, create=True
        ) as restore:
            code, stdout, stderr, _auth_write = self._invoke(
                session="S-auth-restore-fail",
                args="#42",
                auth_side_effect=write_then_fail,
            )

        self.assertEqual(0, code)
        self.assertEqual(1, restore.call_count)
        self.assertIn('"decision": "block"', stdout)
        self.assertIn("authorization state rollback did not persist", stderr.lower())
        self.assertEqual([prior], self._active("S-auth-restore-fail"))


if __name__ == "__main__":
    if len(sys.argv) == 5 and sys.argv[1] == "--race-child":
        _run_race_child(sys.argv[2], sys.argv[3], sys.argv[4])
    else:
        unittest.main()
