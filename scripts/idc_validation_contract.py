#!/usr/bin/env python3
"""Freeze and execute source-owned build validation contracts.

U6 adds a machine-owned validation contract for Build:
  * baseline classification (expected-red vs expected-green) before implementation;
  * an immutable frozen contract the builder cannot edit;
  * source-owned execution receipts for the frozen verification commands.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time

# THE CREDENTIAL SCRUB DOOR — see `idc_credential_shapes.scrub`. Every read of a CHILD PROCESS's
# stderr in this module passes through it AT THE READ, and `tests/smoke/phase11-honesty-repro.sh` R28
# is the census that keeps that true across every module in scripts/.
#
# THE IMPORT IS TOLERANT BECAUSE SEVERAL MODULES HERE RUN AS LONE RELOCATED COPIES. The smoke and
# governance suites copy a single script to a temp directory and execute it there to prove a deleted
# guard was the one doing the work (`phase1-pipe-safety` F, `governance/external-intake-completeness`,
# `phase4-completion-honesty` F) — a hard sibling import makes those copies die on ImportError. The
# fallback FAILS CLOSED: with no table to scrub with, a child's stderr is WITHHELD, never passed
# through. This block is byte-identical everywhere it appears and R28 asserts that, so no copy of it
# can drift into a pass-through.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import idc_credential_shapes as CS  # noqa: E402
except ImportError:                                      # a lone relocated copy — fail closed
    class CS:                                            # noqa: N801 — stand-in for the shared table
        scrub = staticmethod(
            lambda text: text and "[child output withheld — the credential table is not importable]")

import idc_matrix_check  # noqa: E402

SCHEMA_VERSION = 1
CONTRACT_KIND = "build-validation-contract"
EXECUTION_KIND = "verification-execution"
WITNESS_FILE = "idc-build-validation-witnesses.json"


class ValidationError(Exception):
    pass


def die(message: str, code: int = 1):
    sys.stderr.write(f"idc-validation-contract: {message}\n")
    sys.exit(code)


def sha256_json(value) -> str:
    blob = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def sha256_bytes(blob: bytes) -> str:
    return hashlib.sha256(blob).hexdigest()


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _clip(text: str | None, limit: int = 400) -> str:
    if not text:
        return ""
    text = str(text)
    return text if len(text) <= limit else text[: limit - 3] + "..."


def _abs_repo(repo: str) -> str:
    repo_abs = os.path.abspath(repo)
    if not os.path.isdir(repo_abs):
        raise ValidationError(f"repo directory does not exist: {repo}")
    return repo_abs


def _read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _common_git_dir(cwd: str) -> str:
    proc = subprocess.run(
        ["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"],
        capture_output=True,
        text=True,
        timeout=15,
    )
    if proc.returncode != 0:
        proc = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--git-common-dir"],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if proc.returncode != 0:
            detail = _clip(CS.scrub(proc.stderr or proc.stdout or "git rev-parse failed"), 200)
            raise ValidationError(f"{cwd} is not inside a governed git repository ({detail})")
        raw = proc.stdout.strip()
        if not os.path.isabs(raw):
            raw = os.path.abspath(os.path.join(cwd, raw))
        return os.path.realpath(raw)
    return os.path.realpath(os.path.abspath(proc.stdout.strip()))


def _repo_identity(path: str) -> str:
    return os.path.realpath(os.path.dirname(_common_git_dir(path)))


def _repo_context(path: str):
    abs_path = os.path.realpath(os.path.abspath(path))
    parent = os.path.dirname(abs_path) or "."
    common_git_dir = _common_git_dir(parent)
    repo_root = os.path.realpath(os.path.dirname(common_git_dir))
    try:
        rel = os.path.relpath(abs_path, repo_root)
    except ValueError as exc:
        raise ValidationError(f"could not relativize {path} under the repo root ({exc})") from exc
    if rel == ".." or rel.startswith(".." + os.sep):
        raise ValidationError(f"{path} must live under the governed repo root {repo_root}")
    return repo_root, common_git_dir, rel


def _witness_path(common_git_dir: str) -> str:
    return os.path.join(common_git_dir, WITNESS_FILE)


def _read_witnesses(common_git_dir: str):
    path = _witness_path(common_git_dir)
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _digest_file(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _record_witness(kind: str, path: str, doc: dict):
    repo_root, common_git_dir, rel = _repo_context(path)
    digest = _digest_file(path)
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        raise ValidationError("the validation witness store is unreadable")
    witnesses[rel] = {
        "kind": kind,
        "digest": digest,
        "repo_root": repo_root,
        "issue": doc.get("issue"),
        "pr": doc.get("pr"),
        "head": doc.get("head"),
        "diff_digest": doc.get("diff_digest"),
        "contract_digest": doc.get("contract_digest"),
        "validated_at": _now(),
        "validator": os.path.basename(__file__),
    }
    target = _witness_path(common_git_dir)
    fd, tmp = tempfile.mkstemp(prefix=".idc-build-validation.", suffix=".tmp", dir=common_git_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(witnesses, fh, indent=2, sort_keys=True)
            fh.write("\n")
        os.replace(tmp, target)
    except OSError as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise ValidationError(f"could not record the validation witness for {rel} ({exc})") from exc
    return rel


def _witness_problem(kind: str, path: str, doc: dict):
    try:
        repo_root, common_git_dir, rel = _repo_context(path)
    except ValidationError as exc:
        return str(exc)
    witnesses = _read_witnesses(common_git_dir)
    if witnesses is None:
        return "the validation witness store is unreadable"
    rec = witnesses.get(rel)
    if not isinstance(rec, dict):
        return f"no source-owned validation witness is recorded for {rel}"
    if rec.get("kind") != kind:
        return f"the validation witness for {rel} is for {rec.get('kind')!r}, not {kind!r}"
    if rec.get("repo_root") != repo_root:
        return f"the validation witness for {rel} names repo {rec.get('repo_root')!r}, not this repo"
    try:
        digest = _digest_file(path)
    except OSError as exc:
        return f"could not re-read {rel} to verify its witness ({exc})"
    if rec.get("digest") != digest:
        return f"the validation witness for {rel} is stale — its digest no longer matches the file"
    for key in ("issue", "pr", "head", "diff_digest", "contract_digest"):
        expected = rec.get(key)
        actual = doc.get(key)
        if expected is not None and actual is not None and expected != actual:
            return f"the validation witness for {rel} is for {key}={expected!r}, not {actual!r}"
    return None


def atomic_write_json(path: str, data):
    parent = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".idc-build-validation-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        tmp = ""
    finally:
        if tmp and os.path.exists(tmp):
            os.unlink(tmp)


def _ensure_hex(label: str, value: str, width: int = 64) -> str:
    text = str(value or "").strip()
    if not re.fullmatch(rf"[0-9a-f]{{{width}}}", text):
        raise ValidationError(f"{label} must be {width} lowercase hex characters (got {value!r})")
    return text


def _normalize_surfaces(values, label: str):
    if not values:
        raise ValidationError(f"{label} must declare at least one surface")
    normalized = []
    seen = set()
    for raw in values:
        info = idc_matrix_check.normalize_surface(raw)
        if info["normalized"] not in seen:
            normalized.append(info["normalized"])
            seen.add(info["normalized"])
    return normalized


def _git(repo: str, *args: str, text: bool = True):
    proc = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=text)
    if proc.returncode != 0:
        detail = _clip(CS.scrub(proc.stderr or proc.stdout or f"git {' '.join(args)} failed"), 200)
        raise ValidationError(f"git {' '.join(args)} failed: {detail}")
    return proc.stdout if text else proc.stdout


def git_head(repo: str, ref: str = "HEAD") -> str:
    return _git(repo, "rev-parse", ref).strip()


def git_diff_info(repo: str, base_commit: str, ref: str = "HEAD"):
    diff = subprocess.run(["git", "-C", repo, "diff", "--binary", f"{base_commit}...{ref}"], capture_output=True)
    if diff.returncode != 0:
        detail = _clip(CS.scrub((diff.stderr or diff.stdout or b"git diff failed").decode("utf-8", "replace")), 200)
        raise ValidationError(f"git diff --binary {base_commit}...{ref} failed: {detail}")
    names = _git(repo, "diff", "--name-only", f"{base_commit}...{ref}")
    changed = sorted({line.strip() for line in names.splitlines() if line.strip()})
    return {
        "diff_digest": sha256_bytes(diff.stdout),
        "changed_paths": changed,
    }


def _verification_results(repo: str, commands):
    results = []
    for command in commands:
        proc = subprocess.run(
            ["/bin/bash", "-lc", command],
            cwd=repo,
            capture_output=True,
            text=True,
        )
        results.append({
            "command": command,
            "exit_code": int(proc.returncode),
            "stdout_excerpt": _clip(proc.stdout),
            "stderr_excerpt": _clip(CS.scrub(proc.stderr) or ""),
        })
    return results


def _baseline_state(results):
    return "expected-green" if all(row.get("exit_code") == 0 for row in results) else "expected-red"


def _contract_digest(doc: dict) -> str:
    body = dict(doc)
    body.pop("contract_digest", None)
    return sha256_json(body)


def _execution_digest(doc: dict) -> str:
    body = dict(doc)
    body.pop("execution_digest", None)
    return sha256_json(body)


def _planning_receipt_info(path: str):
    if not path:
        return None
    doc = _read_json(path)
    if doc.get("written_by") != "idc_planning_receipt.py":
        raise ValidationError("planning receipt must be written by idc_planning_receipt.py")
    return {
        "path": path,
        "graph_digest": doc.get("graph_digest"),
        "projection_digest": doc.get("projection_digest"),
        "final_digest": doc.get("final_digest"),
    }


def freeze_contract(*, repo: str, issue: int, pr: int, graph_node: str, graph_digest: str | None,
                    projection_digest: str | None, planning_receipt: str | None, touch, off_limits,
                    verify_commands, baseline: str, label: str, out: str, attempt_ceiling: int = 3):
    workspace = _abs_repo(repo)
    repo = _repo_identity(workspace)
    planning = _planning_receipt_info(planning_receipt) if planning_receipt else None
    if planning:
        graph_digest = graph_digest or planning.get("graph_digest")
        projection_digest = projection_digest or planning.get("projection_digest")
    graph_node = str(graph_node or "").strip()
    if not graph_node:
        raise ValidationError("graph_node must be non-empty")
    graph_digest = _ensure_hex("graph_digest", graph_digest)
    projection_digest = _ensure_hex("projection_digest", projection_digest)
    if baseline not in {"expected-red", "expected-green"}:
        raise ValidationError(f"baseline must be expected-red or expected-green, got {baseline!r}")
    commands = [str(cmd).strip() for cmd in (verify_commands or []) if str(cmd).strip()]
    if not commands:
        raise ValidationError("at least one --verify command is required")
    if attempt_ceiling <= 0:
        raise ValidationError("attempt_ceiling must be positive")
    touch_surfaces = _normalize_surfaces(touch, "touch")
    off_limits_surfaces = _normalize_surfaces(off_limits, "off-limits")
    base_commit = git_head(workspace)
    baseline_results = _verification_results(workspace, commands)
    actual = _baseline_state(baseline_results)
    if actual != baseline:
        raise ValidationError(f"unexpected-green baseline refusal: expected {baseline}, actual {actual}")
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kind": CONTRACT_KIND,
        "written_by": os.path.basename(__file__),
        "created_at": _now(),
        "repo": repo,
        "workspace": workspace,
        "label": str(label or "build-validation").strip() or "build-validation",
        "issue": int(issue),
        "pr": int(pr),
        "graph_node": graph_node,
        "graph_digest": graph_digest,
        "projection_digest": projection_digest,
        "planning_receipt": os.path.relpath(planning["path"], repo) if planning else None,
        "planning_final_digest": planning.get("final_digest") if planning else None,
        "base_commit": base_commit,
        "attempt_ceiling": int(attempt_ceiling),
        "touch": touch_surfaces,
        "off_limits": off_limits_surfaces,
        "verification": [{"command": cmd} for cmd in commands],
        "baseline": {
            "expected": baseline,
            "actual": actual,
            "head": base_commit,
            "results": baseline_results,
        },
    }
    doc["contract_digest"] = _contract_digest(doc)
    atomic_write_json(out, doc)
    _record_witness("contract", out, doc)
    return doc


def load_contract(path: str, require_witness: bool = True):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ValidationError(f"could not read frozen contract {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"frozen contract {path} is invalid JSON: {exc}") from exc
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(f"frozen contract schema_version must be {SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("kind") != CONTRACT_KIND:
        raise ValidationError(f"frozen contract kind must be {CONTRACT_KIND!r}, got {doc.get('kind')!r}")
    if doc.get("written_by") != os.path.basename(__file__):
        raise ValidationError("frozen contract must be source-owned by idc_validation_contract.py")
    expected = _contract_digest(doc)
    if doc.get("contract_digest") != expected:
        raise ValidationError("frozen contract digest mismatch — the frozen gate was modified after issuance")
    if require_witness:
        problem = _witness_problem("contract", path, doc)
        if problem:
            raise ValidationError(problem)
    return doc


def run_contract(*, repo: str, contract_path: str, out: str):
    contract = load_contract(contract_path)
    workspace = _abs_repo(repo)
    if _repo_identity(workspace) != os.path.abspath(contract.get("repo") or ""):
        raise ValidationError("validation contract is bound to a different repo identity")
    commands = [row.get("command") for row in contract.get("verification") or []]
    results = _verification_results(workspace, commands)
    diff_info = git_diff_info(workspace, contract["base_commit"], ref="HEAD")
    head = git_head(workspace)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kind": EXECUTION_KIND,
        "written_by": os.path.basename(__file__),
        "created_at": _now(),
        "repo": contract.get("repo"),
        "workspace": workspace,
        "label": contract.get("label"),
        "issue": contract.get("issue"),
        "pr": contract.get("pr"),
        "graph_node": contract.get("graph_node"),
        "graph_digest": contract.get("graph_digest"),
        "projection_digest": contract.get("projection_digest"),
        "contract_path": os.path.relpath(os.path.abspath(contract_path), repo),
        "contract_digest": contract.get("contract_digest"),
        "base_commit": contract.get("base_commit"),
        "head": head,
        "diff_digest": diff_info["diff_digest"],
        "changed_paths": diff_info["changed_paths"],
        "verification": results,
        "result": "pass" if all(row.get("exit_code") == 0 for row in results) else "fail",
    }
    doc["execution_digest"] = _execution_digest(doc)
    atomic_write_json(out, doc)
    _record_witness("execution", out, doc)
    return doc


def load_execution(path: str, require_witness: bool = True):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ValidationError(f"could not read execution receipt {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationError(f"execution receipt {path} is invalid JSON: {exc}") from exc
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ValidationError(f"execution receipt schema_version must be {SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("kind") != EXECUTION_KIND:
        raise ValidationError(f"execution receipt kind must be {EXECUTION_KIND!r}, got {doc.get('kind')!r}")
    if doc.get("written_by") != os.path.basename(__file__):
        raise ValidationError("execution receipt must be source-owned by idc_validation_contract.py")
    expected = _execution_digest(doc)
    if doc.get("execution_digest") != expected:
        raise ValidationError("execution receipt digest mismatch — the recorded execution was modified after it ran")
    if require_witness:
        problem = _witness_problem("execution", path, doc)
        if problem:
            raise ValidationError(problem)
    return doc


def main(argv=None):
    ap = argparse.ArgumentParser(description="Freeze and execute build validation contracts.")
    sp = ap.add_subparsers(dest="command", required=True)

    fp = sp.add_parser("freeze")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--issue", type=int, required=True)
    fp.add_argument("--pr", type=int, required=True)
    fp.add_argument("--graph-node", required=True)
    fp.add_argument("--graph-digest")
    fp.add_argument("--projection-digest")
    fp.add_argument("--planning-receipt")
    fp.add_argument("--touch", action="append", required=True)
    fp.add_argument("--off-limits", action="append", required=True)
    fp.add_argument("--verify", action="append", required=True)
    fp.add_argument("--baseline", required=True, choices=("expected-red", "expected-green"))
    fp.add_argument("--label", required=True)
    fp.add_argument("--out", required=True)
    fp.add_argument("--attempt-ceiling", type=int, default=3)

    rp = sp.add_parser("run")
    rp.add_argument("--repo", required=True)
    rp.add_argument("--contract", required=True)
    rp.add_argument("--out", required=True)

    args = ap.parse_args(argv)
    try:
        if args.command == "freeze":
            freeze_contract(
                repo=args.repo,
                issue=args.issue,
                pr=args.pr,
                graph_node=args.graph_node,
                graph_digest=args.graph_digest,
                projection_digest=args.projection_digest,
                planning_receipt=args.planning_receipt,
                touch=args.touch,
                off_limits=args.off_limits,
                verify_commands=args.verify,
                baseline=args.baseline,
                label=args.label,
                out=args.out,
                attempt_ceiling=args.attempt_ceiling,
            )
            return 0
        if args.command == "run":
            doc = run_contract(repo=args.repo, contract_path=args.contract, out=args.out)
            json.dump({
                "ok": True,
                "result": doc.get("result"),
                "head": doc.get("head"),
                "diff_digest": doc.get("diff_digest"),
            }, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
    except ValidationError as exc:
        die(str(exc), code=2)
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    raise SystemExit(main())
