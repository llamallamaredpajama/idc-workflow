#!/usr/bin/env python3
"""Durable adoption-baseline state for U7 reconciliation.

This module owns the governed-repo files Janitor and the command-entry gate use to reason about the
adoption boundary:

* ``docs/workflow/reconciliation-baseline-required.json`` — durable baseline-pending marker.
* ``docs/workflow/reconciliation-adoption.json`` — durable adoption receipt.
* ``docs/workflow/reconciliation-checkpoint.json`` — durable convergence checkpoint.
* ``<git-dir>/idc-reconciliation-cursor.json`` — local scan accelerator only.

The marker and receipt are clone-portable repository state. The cursor is intentionally local and may
be deleted at any time; callers must rescan from durable evidence rather than treating its absence as
amnesty.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import stat
import subprocess
import sys
import tempfile
from typing import Any

SCHEMA_VERSION = 1
MARKER_RELPATH = os.path.join("docs", "workflow", "reconciliation-baseline-required.json")
RECEIPT_RELPATH = os.path.join("docs", "workflow", "reconciliation-adoption.json")
CHECKPOINT_RELPATH = os.path.join("docs", "workflow", "reconciliation-checkpoint.json")
CURSOR_BASENAME = "idc-reconciliation-cursor.json"
PENDING_STATE = "baseline-pending"
ADOPTED_STATE = "legacy-adopted"
REQUIRED_REASON = "reconciliation-baseline-required"


class BaselineError(RuntimeError):
    """Malformed or unreadable durable reconciliation state."""


def _utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _repo_abspath(repo: str) -> str:
    return os.path.abspath(repo)


def marker_path(repo: str) -> str:
    return os.path.join(_repo_abspath(repo), MARKER_RELPATH)


def receipt_path(repo: str) -> str:
    return os.path.join(_repo_abspath(repo), RECEIPT_RELPATH)


def checkpoint_path(repo: str) -> str:
    return os.path.join(_repo_abspath(repo), CHECKPOINT_RELPATH)


def git_dir(repo: str) -> str:
    try:
        out = subprocess.run(
            ["git", "-C", _repo_abspath(repo), "rev-parse", "--git-dir"],
            capture_output=True,
            text=True,
            check=False,
        )
    except (OSError, ValueError) as exc:
        raise BaselineError(f"could not resolve git dir: {exc}") from exc
    if out.returncode != 0 or not out.stdout.strip():
        raise BaselineError("could not resolve git dir")
    path = out.stdout.strip()
    if not os.path.isabs(path):
        path = os.path.join(_repo_abspath(repo), path)
    return os.path.abspath(path)


def cursor_path(repo: str) -> str:
    return os.path.join(git_dir(repo), CURSOR_BASENAME)


def _atomic_write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    fd = -1
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(prefix=".reconciliation-", suffix=".tmp", dir=parent)
        if os.path.exists(path):
            os.chmod(tmp, stat.S_IMODE(os.stat(path).st_mode))
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        tmp = ""
    except OSError as exc:
        raise BaselineError(f"could not write {path}: {exc}") from exc
    finally:
        if fd != -1:
            os.close(fd)
        if tmp and os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def _read_json(path: str, label: str) -> dict[str, Any] | None:
    if not os.path.exists(path):
        return None
    try:
        with open(path, encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise BaselineError(f"could not read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise BaselineError(f"{label} must be a JSON object")
    return value


def _validate_default_branch(value: Any, label: str) -> dict[str, str] | None:
    if value is None:
        return None
    if not isinstance(value, dict):
        raise BaselineError(f"{label} must be an object")
    name = value.get("name")
    head = value.get("head")
    if not isinstance(name, str) or not name.strip() or not isinstance(head, str) or not head.strip():
        raise BaselineError(f"{label} must carry non-empty name/head strings")
    return {"name": name.strip(), "head": head.strip()}


def _validate_marker(value: dict[str, Any]) -> dict[str, Any]:
    if value.get("schema_version") != SCHEMA_VERSION:
        raise BaselineError("baseline marker schema_version must be 1")
    if value.get("state") != PENDING_STATE:
        raise BaselineError("baseline marker state must be baseline-pending")
    reason = value.get("reason")
    if not isinstance(reason, str) or not reason.strip():
        raise BaselineError("baseline marker reason must be non-empty")
    default_branch = _validate_default_branch(value.get("default_branch"), "baseline marker default_branch")
    in_progress = value.get("in_progress")
    if in_progress is not None and not isinstance(in_progress, dict):
        raise BaselineError("baseline marker in_progress must be an object when present")
    resume = value.get("resume")
    if resume is not None and not isinstance(resume, dict):
        raise BaselineError("baseline marker resume must be an object when present")
    out = dict(value)
    out["reason"] = reason.strip()
    out["default_branch"] = default_branch
    return out


def _validate_receipt(value: dict[str, Any]) -> dict[str, Any]:
    if value.get("schema_version") != SCHEMA_VERSION:
        raise BaselineError("adoption receipt schema_version must be 1")
    if value.get("state") != ADOPTED_STATE:
        raise BaselineError("adoption receipt state must be legacy-adopted")
    out = dict(value)
    out["default_branch"] = _validate_default_branch(
        value.get("default_branch"), "adoption receipt default_branch")
    if out["default_branch"] is None:
        raise BaselineError("adoption receipt must record default_branch")
    for key in ("legacy_items", "routed_obligations", "unresolved"):
        raw = value.get(key)
        if not isinstance(raw, list):
            raise BaselineError(f"adoption receipt {key} must be a list")
    return out


def _validate_checkpoint(value: dict[str, Any]) -> dict[str, Any]:
    if value.get("schema_version") != SCHEMA_VERSION:
        raise BaselineError("checkpoint schema_version must be 1")
    for key in ("resolved_root_ids", "blocked_root_ids"):
        raw = value.get(key, [])
        if not isinstance(raw, list) or any(not isinstance(item, str) or not item for item in raw):
            raise BaselineError(f"checkpoint {key} must be a list of non-empty strings")
    return value


def read_marker(repo: str) -> dict[str, Any] | None:
    value = _read_json(marker_path(repo), "baseline marker")
    return None if value is None else _validate_marker(value)


def read_receipt(repo: str) -> dict[str, Any] | None:
    value = _read_json(receipt_path(repo), "adoption receipt")
    return None if value is None else _validate_receipt(value)


def read_checkpoint(repo: str) -> dict[str, Any] | None:
    value = _read_json(checkpoint_path(repo), "reconciliation checkpoint")
    return None if value is None else _validate_checkpoint(value)


def read_cursor(repo: str) -> dict[str, Any] | None:
    value = _read_json(cursor_path(repo), "reconciliation cursor")
    if value is None:
        return None
    if value.get("schema_version") != SCHEMA_VERSION:
        raise BaselineError("cursor schema_version must be 1")
    return value


def write_marker(
    repo: str,
    *,
    default_branch_name: str | None = None,
    default_branch_head: str | None = None,
    in_progress: dict[str, Any] | None = None,
    resume: dict[str, Any] | None = None,
) -> dict[str, Any]:
    existing = read_marker(repo) or {}
    default_branch = existing.get("default_branch") or None
    if default_branch_name and default_branch_head:
        default_branch = {"name": default_branch_name, "head": default_branch_head}
    marker = {
        "schema_version": SCHEMA_VERSION,
        "state": PENDING_STATE,
        "reason": REQUIRED_REASON,
        "created_at": existing.get("created_at") or _utc_now(),
        "updated_at": _utc_now(),
        "default_branch": default_branch,
        "in_progress": in_progress or existing.get("in_progress") or {},
        "resume": resume or existing.get("resume") or {},
    }
    _atomic_write_json(marker_path(repo), marker)
    return marker


def write_receipt(repo: str, receipt: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(receipt)
    normalized.setdefault("schema_version", SCHEMA_VERSION)
    normalized["state"] = ADOPTED_STATE
    if normalized.get("default_branch") is None:
        marker = read_marker(repo)
        if marker and marker.get("default_branch"):
            normalized["default_branch"] = marker["default_branch"]
    validated = _validate_receipt(normalized)
    _atomic_write_json(receipt_path(repo), validated)
    return validated


def write_checkpoint(repo: str, checkpoint: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(checkpoint)
    normalized.setdefault("schema_version", SCHEMA_VERSION)
    normalized.setdefault("resolved_root_ids", [])
    normalized.setdefault("blocked_root_ids", [])
    normalized.setdefault("updated_at", _utc_now())
    validated = _validate_checkpoint(normalized)
    _atomic_write_json(checkpoint_path(repo), validated)
    return validated


def write_cursor(repo: str, cursor: dict[str, Any]) -> dict[str, Any]:
    normalized = dict(cursor)
    normalized.setdefault("schema_version", SCHEMA_VERSION)
    normalized.setdefault("updated_at", _utc_now())
    _atomic_write_json(cursor_path(repo), normalized)
    return normalized


def clear_marker(repo: str) -> None:
    path = marker_path(repo)
    if os.path.exists(path):
        try:
            os.unlink(path)
        except OSError as exc:
            raise BaselineError(f"could not clear baseline marker: {exc}") from exc


def clear_cursor(repo: str) -> None:
    path = cursor_path(repo)
    if os.path.exists(path):
        try:
            os.unlink(path)
        except OSError as exc:
            raise BaselineError(f"could not clear cursor: {exc}") from exc


def status(repo: str) -> dict[str, Any]:
    marker = read_marker(repo)
    receipt = read_receipt(repo)
    checkpoint = read_checkpoint(repo)
    cursor = read_cursor(repo)
    state = "not-required"
    if marker:
        state = PENDING_STATE
    elif receipt:
        state = ADOPTED_STATE
    return {
        "schema_version": SCHEMA_VERSION,
        "state": state,
        "pending": bool(marker),
        "marker_present": bool(marker),
        "receipt_present": bool(receipt),
        "checkpoint_present": bool(checkpoint),
        "cursor_present": bool(cursor),
        "marker_path": MARKER_RELPATH,
        "receipt_path": RECEIPT_RELPATH,
        "checkpoint_path": CHECKPOINT_RELPATH,
        "cursor_path": CURSOR_BASENAME,
        "default_branch": (marker or receipt or {}).get("default_branch"),
        "reason": marker.get("reason") if marker else None,
    }


def finalize_bootstrap(repo: str, receipt: dict[str, Any], checkpoint: dict[str, Any]) -> dict[str, Any]:
    write_checkpoint(repo, checkpoint)
    written = write_receipt(repo, receipt)
    clear_marker(repo)
    return written


def _cmd_status(args: argparse.Namespace) -> int:
    value = status(args.repo)
    if args.json:
        print(json.dumps(value, sort_keys=True))
    else:
        print(f"reconciliation-baseline: {value['state']}")
    return 0


def _cmd_require(args: argparse.Namespace) -> int:
    marker = write_marker(
        args.repo,
        default_branch_name=args.default_branch,
        default_branch_head=args.default_head,
    )
    if args.json:
        print(json.dumps(marker, sort_keys=True))
    else:
        print(PENDING_STATE)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("status", help="report adoption-baseline state")
    s.add_argument("--repo", required=True)
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=_cmd_status)

    r = sub.add_parser("require", help="write the baseline-pending marker")
    r.add_argument("--repo", required=True)
    r.add_argument("--default-branch")
    r.add_argument("--default-head")
    r.add_argument("--json", action="store_true")
    r.set_defaults(func=_cmd_require)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except BaselineError as exc:
        print(f"idc-reconciliation-baseline: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
