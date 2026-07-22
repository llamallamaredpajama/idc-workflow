#!/usr/bin/env python3
"""Shared IDC Path Gate core.

One deterministic policy core for runtime/file/git mutation authorization. Adapters translate a tool
payload into a normalized request and this module returns allow/deny plus remediation.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fnmatch
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from typing import Any

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
HOOKS_DIR = os.path.join(SCRIPT_DIR, "hooks")
sys.path.insert(0, SCRIPT_DIR)
sys.path.insert(0, HOOKS_DIR)

import idc_command_contract as C  # noqa: E402
import idc_credential_shapes as CS  # noqa: E402
import idc_ledger as L  # noqa: E402

AUTH_RELPATH = os.path.join("idc-path-gate", "authorization.json")
ADMISSION_LOCK_RELPATH = os.path.join("idc-path-gate", "admission.lock")
PROTECTED_MACHINE_RULES = [
    "TRACKER.md",
    "TRACKER-archive.md",
    "docs/workflow/install-receipt.yaml",
    "docs/workflow/transition-journal.ndjson",
    "docs/workflow/transition-journal.ndjson.*",
    ".idc-session-state.json*",
    ".idc-drain-verdict.json*",
    ".idc-*-report.json*",
    ".idc-pause-state.json*",
]
READ_ONLY_COMMANDS = {"doctor", "pause"}
DEFAULT_TTL_SECONDS = 4 * 60 * 60
PATHWAY_MODES = {"off", "controlled", "app-locked"}

try:
    import fcntl  # POSIX advisory locks (macOS/Linux — IDC's supported platforms)
except ImportError:  # pragma: no cover - unsupported platform fails closed at acquisition
    fcntl = None


def _utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def _iso(ts: dt.datetime) -> str:
    return ts.astimezone(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _parse_iso(value: str) -> dt.datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    except ValueError:
        return None


def _run_git(repo: str, *args: str) -> str:
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(CS.scrub(proc.stderr or proc.stdout or "git failed").strip())
    return (proc.stdout or "").strip()


def repo_root(repo: str) -> str:
    return os.path.realpath(os.path.abspath(repo))


def _is_git_worktree(repo: str) -> bool:
    proc = subprocess.run(
        ["git", "-C", repo, "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
        text=True,
    )
    return proc.returncode == 0 and (proc.stdout or "").strip() == "true"


def pathway_mode(repo: str) -> str:
    """Read the scaffolded pathway posture without taking a YAML dependency."""
    config_path = os.path.join(repo_root(repo), "WORKFLOW-config.yaml")
    try:
        with open(config_path, encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError:
        return "off"

    block_indent: int | None = None
    for raw_line in lines:
        content = raw_line.split("#", 1)[0].rstrip()
        if not content.strip():
            continue
        indent = len(content) - len(content.lstrip())
        stripped = content.strip()
        if block_indent is None:
            if stripped == "pathway_enforcement:":
                block_indent = indent
            continue
        if indent <= block_indent:
            break
        key, separator, raw_value = stripped.partition(":")
        if separator and key.strip() == "mode":
            value = raw_value.strip().strip("\"'")
            return value if value in PATHWAY_MODES else "off"
    return "off"


def current_branch(repo: str) -> str:
    return _run_git(repo, "branch", "--show-current")


def git_path(repo: str, relpath: str) -> str:
    out = _run_git(repo, "rev-parse", "--git-path", relpath)
    return os.path.normpath(out if os.path.isabs(out) else os.path.join(repo, out))


def auth_path(repo: str) -> str:
    return git_path(repo, AUTH_RELPATH)


def admission_lock_path(repo: str) -> str:
    return git_path(repo, ADMISSION_LOCK_RELPATH)


@contextlib.contextmanager
def admission_lock(repo: str):
    """Serialize command-entry registration -> authorization/rollback across processes.

    This safety lock is fail-closed (unlike the ledger's best-effort observer lock): without it two
    admission processes can overwrite the same active record between start and authorization. Lock
    order is admission lock -> ledger write lock -> authorization atomic write; no code acquires the
    admission lock from inside either lower-level lock."""
    if fcntl is None:
        raise RuntimeError("Path Gate admission locking is unavailable on this platform")
    path = admission_lock_path(repo)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    try:
        fh = open(path, "a", encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot open Path Gate admission lock: {CS.scrub(str(exc))}") from exc
    try:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        except OSError as exc:
            raise RuntimeError(f"cannot acquire Path Gate admission lock: {CS.scrub(str(exc))}") from exc
        yield
    finally:
        try:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        except OSError:
            pass
        fh.close()


def _atomic_write_json(path: str, payload: dict[str, Any]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".idc-path-gate.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(payload, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def authorization_snapshot(repo: str) -> bytes | None:
    """Exact authorization bytes for command-entry rollback, or None when absent."""
    try:
        with open(auth_path(repo), "rb") as fh:
            return fh.read()
    except FileNotFoundError:
        return None


def _atomic_write_bytes(path: str, payload: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".idc-path-gate.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(payload)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def restore_authorization_snapshot(repo: str, snapshot: bytes | None, expected_nonce: str) -> bool:
    """Restore exact pre-admission auth iff current auth is this attempt (nonce CAS).

    Called only while `admission_lock` is held and before command expansion. There is deliberately no
    CLI operation for this internal transaction repair."""
    path = auth_path(repo)
    try:
        with open(path, "rb") as fh:
            current = fh.read()
    except FileNotFoundError:
        current = None
    if current == snapshot:
        return True
    try:
        decoded = json.loads(current.decode("utf-8")) if current is not None else None
    except (UnicodeDecodeError, ValueError):
        return False
    if not isinstance(decoded, dict) or decoded.get("nonce") != str(expected_nonce):
        return False
    if snapshot is None:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
    else:
        _atomic_write_bytes(path, snapshot)
    try:
        with open(path, "rb") as fh:
            restored = fh.read()
    except FileNotFoundError:
        restored = None
    return restored == snapshot


def _request_repo_rel(path_value: str, repo: str) -> str | None:
    if not isinstance(path_value, str) or not path_value.strip():
        raise ValueError("path must be a non-empty string")
    raw = path_value.strip()
    repo_abs = repo_root(repo)
    abs_path = os.path.realpath(raw if os.path.isabs(raw) else os.path.join(repo_abs, raw))
    rel = os.path.relpath(abs_path, repo_abs)
    if rel == ".":
        return "."
    if rel.startswith("..") or os.path.isabs(rel):
        return None
    return rel.replace(os.sep, "/")


def _normalize_repo_rel(path_value: str, repo: str) -> str:
    rel = _request_repo_rel(path_value, repo)
    if rel is None:
        raise ValueError(f"{path_value!r} escapes the repository root")
    return rel


def _normalize_allowed_paths(repo: str, paths: list[str]) -> list[str]:
    out = []
    for item in paths:
        rel = _normalize_repo_rel(item, repo)
        if rel.endswith("/") and rel != "/":
            rel = rel.rstrip("/")
        if rel not in out:
            out.append(rel)
    return out or ["."]


def _path_allowed(relpath: str, allowed_paths: list[str]) -> bool:
    for rule in allowed_paths:
        base = rule.rstrip("/") or "."
        if base == ".":
            return True
        if relpath == base or relpath.startswith(base + "/"):
            return True
    return False


def _is_protected_machine_path(relpath: str) -> bool:
    candidate = relpath.casefold()
    return any(fnmatch.fnmatchcase(candidate, rule.casefold()) for rule in PROTECTED_MACHINE_RULES)


def _find_active_record_by_nonce(repo: str, command: str, nonce: str) -> dict[str, Any] | None:
    state = L.read_state(repo)
    for rec in state.get("commands", []):
        if rec.get("state") == "active" and rec.get("command") == command and rec.get("nonce") == nonce:
            return rec
    return None


def _default_profile(command: str) -> tuple[list[str], list[str]]:
    if command in READ_ONLY_COMMANDS:
        return ["."], []
    return ["."], ["write", "edit", "git"]


def _digest_payload(record: dict[str, Any], auth: dict[str, Any]) -> str:
    payload = {
        "args_sha256": record.get("args_sha256", ""),
        "allowed_actions": list(auth.get("allowed_actions") or []),
        "allowed_paths": list(auth.get("allowed_paths") or []),
        "branch": auth.get("branch", ""),
        "command": auth.get("command", ""),
        "graph_node": auth.get("graph_node", ""),
        "nonce": auth.get("nonce", ""),
        "plugin_version": record.get("plugin_version", ""),
        "source": record.get("source", ""),
        "ticket": auth.get("ticket", ""),
    }
    blob = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def _deny(reason: str, remediation: str | None = None) -> dict[str, Any]:
    out = {"allowed": False, "reason": reason}
    if remediation:
        out["remediation"] = remediation
    return out


def _allow(reason: str) -> dict[str, Any]:
    return {"allowed": True, "reason": reason}


def _no_auth_reason() -> str:
    return (
        "IDC Path Gate denied this mutation because the live authorization is absent for this repository mutation. "
        "Route the work through an existing IDC command (think, intake, plan, build, recirculate, init, update, or a sanctioned recovery door) so IDC can open the sanctioned write path."
    )


def build_authorization(
    repo: str,
    *,
    record: dict[str, Any],
    command: str,
    branch: str,
    allowed_paths: list[str],
    allowed_actions: list[str],
    ticket: str | None,
    graph_node: str | None,
    ttl_seconds: int,
) -> dict[str, Any]:
    now = _utc_now()
    auth = {
        "schema": 1,
        "command": command,
        "ticket": ticket,
        "graph_node": graph_node or f"command:{command}",
        "branch": branch,
        "allowed_paths": allowed_paths,
        "allowed_actions": allowed_actions,
        "issued_at": _iso(now),
        "expires_at": _iso(now + dt.timedelta(seconds=max(1, ttl_seconds))),
        "nonce": record.get("nonce", ""),
    }
    auth["contract_digest"] = _digest_payload(record, auth)
    return auth


def write_authorization(
    repo: str,
    *,
    session: str,
    command: str,
    branch: str | None = None,
    allowed_paths: list[str] | None = None,
    allowed_actions: list[str] | None = None,
    ticket: str | None = None,
    graph_node: str | None = None,
    ttl_seconds: int = DEFAULT_TTL_SECONDS,
    expected_nonce: str | None = None,
) -> dict[str, Any]:
    records = [rec for rec in C.active_records(repo, session) if rec.get("command") == command]
    if not records:
        raise RuntimeError(f"no active command record found for session={session!r}, command={command!r}")
    if expected_nonce is not None:
        record = next(
            (rec for rec in records if rec.get("nonce") == str(expected_nonce)),
            None,
        )
        if record is None:
            raise RuntimeError(
                "active command record no longer matches the expected admission nonce; "
                "the admission attempt is no longer current"
            )
    else:
        record = records[0]
    if not record.get("nonce"):
        raise RuntimeError("active command record carries no nonce")
    branch = branch or current_branch(repo)
    if allowed_paths is None or allowed_actions is None:
        def_paths, def_actions = _default_profile(command)
        allowed_paths = def_paths if allowed_paths is None else allowed_paths
        allowed_actions = def_actions if allowed_actions is None else allowed_actions
    auth = build_authorization(
        repo,
        record=record,
        command=command,
        branch=branch,
        allowed_paths=_normalize_allowed_paths(repo, list(allowed_paths)),
        allowed_actions=list(dict.fromkeys(allowed_actions)),
        ticket=ticket,
        graph_node=graph_node,
        ttl_seconds=ttl_seconds,
    )
    _atomic_write_json(auth_path(repo), auth)
    return auth


def _read_authorization(repo: str) -> tuple[str, dict[str, Any] | None]:
    path = auth_path(repo)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return "absent", None
    except OSError:
        return "unreadable", None
    except ValueError:
        return "corrupt", None
    if not isinstance(data, dict):
        return "corrupt", None
    return "ok", data


def _evaluate_request(repo: str, plugin_root: str, request: dict[str, Any]) -> dict[str, Any]:
    del plugin_root  # reserved for future transport-specific helpers

    raw_reason = request.get("raw_reason")
    if isinstance(raw_reason, str) and raw_reason.strip():
        return _deny(raw_reason.strip())

    action = str(request.get("action") or "").strip().lower()
    raw_paths = request.get("paths") or []
    if isinstance(raw_paths, str):
        raw_paths = [raw_paths]
    if not isinstance(raw_paths, list):
        raw_paths = []
    try:
        paths = [
            rel
            for p in raw_paths
            if isinstance(p, str) and p.strip()
            for rel in [_request_repo_rel(p, repo)]
            if rel is not None
        ]
    except ValueError as exc:
        return _deny(f"IDC Path Gate denied this mutation because the requested path is invalid: {exc}")

    if not paths:
        return _allow("IDC Path Gate: no in-repository path-gated mutation was identified")

    for rel in paths:
        if _is_protected_machine_path(rel):
            return _deny(
                f"IDC Path Gate denied this mutation because `{rel}` is a protected machine-owned surface. Use the sanctioned IDC helper instead of mutating it directly."
            )

    if not _is_git_worktree(repo):
        return _allow("IDC Path Gate: ordinary mutation is inside a governed non-Git repository")

    auth_state, auth = _read_authorization(repo)
    if auth_state == "absent":
        return _deny(_no_auth_reason())
    if auth_state == "unreadable":
        return _deny("IDC Path Gate denied this mutation because the live authorization is unreadable.")
    if auth_state == "corrupt":
        return _deny("IDC Path Gate denied this mutation because the live authorization is corrupt.")
    assert auth is not None

    if auth.get("schema") != 1:
        return _deny("IDC Path Gate denied this mutation because the authorization object is missing or has the wrong schema.")
    required = ("command", "branch", "allowed_paths", "allowed_actions", "issued_at", "expires_at", "nonce", "contract_digest")
    for field in required:
        if field not in auth:
            return _deny(f"IDC Path Gate denied this mutation because the authorization object is missing `{field}`.")

    if action not in {str(x).strip().lower() for x in auth.get("allowed_actions") or []}:
        return _deny(f"IDC Path Gate denied this mutation because action `{action}` is not in the live authorization.")

    current = current_branch(repo)
    if auth.get("branch") != current:
        return _deny(
            f"IDC Path Gate denied this mutation because the live branch is `{current}` but the authorization is bound to `{auth.get('branch')}`."
        )

    expires_at = _parse_iso(str(auth.get("expires_at") or ""))
    if expires_at is None or expires_at <= _utc_now():
        return _deny("IDC Path Gate denied this mutation because the live authorization is expired or unreadable.")

    ticket = request.get("ticket")
    if ticket is not None and ticket != auth.get("ticket"):
        return _deny("IDC Path Gate denied this mutation because the request ticket does not match the live authorization.")
    graph_node = request.get("graph_node")
    if graph_node is not None and graph_node != auth.get("graph_node"):
        return _deny("IDC Path Gate denied this mutation because the request graph node does not match the live authorization.")

    record = _find_active_record_by_nonce(repo, str(auth.get("command") or ""), str(auth.get("nonce") or ""))
    if not record:
        return _deny("IDC Path Gate denied this mutation because the bound command record is no longer active.")

    expected_digest = _digest_payload(record, auth)
    if auth.get("contract_digest") != expected_digest:
        return _deny("IDC Path Gate denied this mutation because the authorization contract digest is corrupt or stale.")

    allowed_paths = _normalize_allowed_paths(repo, list(auth.get("allowed_paths") or []))
    for rel in paths:
        if not _path_allowed(rel, allowed_paths):
            return _deny(
                f"IDC Path Gate denied this mutation because `{rel}` is outside the live authorization boundary ({', '.join(allowed_paths)})."
            )

    return _allow("IDC Path Gate: mutation is inside the live authorization boundary")


def evaluate_request(repo: str, plugin_root: str, request: dict[str, Any]) -> dict[str, Any]:
    """Evaluate once, then apply the repository's transport-independent enforcement posture."""
    decision = _evaluate_request(repo, plugin_root, request)
    if decision.get("allowed"):
        return decision
    if os.environ.get("IDC_HOOKS_OBSERVE_ONLY", "") == "1" or pathway_mode(repo) == "off":
        return {
            "allowed": True,
            "observe": str(decision.get("reason") or "IDC Path Gate would deny this mutation"),
        }
    return decision


def _read_request_from_stdin() -> dict[str, Any]:
    raw = sys.stdin.read()
    if not raw.strip():
        return {}
    data = json.loads(raw)
    if not isinstance(data, dict):
        raise RuntimeError("request JSON must be an object")
    return data


def cmd_auth_path(args: argparse.Namespace) -> int:
    print(auth_path(repo_root(args.repo)))
    return 0


def cmd_authorize(args: argparse.Namespace) -> int:
    auth = write_authorization(
        repo_root(args.repo),
        session=args.session,
        command=args.command,
        branch=args.branch,
        allowed_paths=args.allow_path,
        allowed_actions=args.allow_action,
        ticket=args.ticket,
        graph_node=args.graph_node,
        ttl_seconds=args.ttl_seconds,
    )
    print(json.dumps(auth, indent=2, sort_keys=True))
    return 0


def cmd_evaluate(args: argparse.Namespace) -> int:
    req = _read_request_from_stdin()
    decision = evaluate_request(repo_root(args.repo), args.plugin_root or "", req)
    print(json.dumps(decision, indent=2, sort_keys=True))
    return 0 if decision.get("allowed") else 2


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="op", required=True)

    p = sub.add_parser("auth-path")
    p.add_argument("--repo", required=True)
    p.set_defaults(func=cmd_auth_path)

    p = sub.add_parser("authorize")
    p.add_argument("--repo", required=True)
    p.add_argument("--session", required=True)
    p.add_argument("--command", required=True)
    p.add_argument("--branch")
    p.add_argument("--ticket")
    p.add_argument("--graph-node")
    p.add_argument("--ttl-seconds", type=int, default=DEFAULT_TTL_SECONDS)
    p.add_argument("--allow-path", action="append", default=None)
    p.add_argument("--allow-action", action="append", default=None)
    p.set_defaults(func=cmd_authorize)

    p = sub.add_parser("evaluate")
    p.add_argument("--repo", required=True)
    p.add_argument("--plugin-root", default="")
    p.set_defaults(func=cmd_evaluate)

    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except Exception as exc:  # noqa: BLE001
        print(json.dumps(_deny(f"IDC Path Gate infrastructure error: {exc}"), indent=2, sort_keys=True))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
