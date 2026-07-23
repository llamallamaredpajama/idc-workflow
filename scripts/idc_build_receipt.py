#!/usr/bin/env python3
"""Write and verify source-owned implementation receipts bound to the final diff."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import idc_matrix_check  # noqa: E402
import idc_review_verdict_check as RV  # noqa: E402
import idc_validation_contract as VC  # noqa: E402

SCHEMA_VERSION = 1
RECEIPT_KIND = "verified-implementation"


class ReceiptError(Exception):
    pass


def die(message: str, code: int = 1):
    sys.stderr.write(f"idc-build-receipt: {message}\n")
    sys.exit(code)


def _read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _digest_file(path: str) -> str:
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def _receipt_digest(doc: dict) -> str:
    body = dict(doc)
    body.pop("receipt_digest", None)
    return VC.sha256_json(body)


def _ensure_hex(label: str, value: str, width: int = 64):
    text = str(value or "").strip()
    if not re.fullmatch(rf"[0-9a-f]{{{width}}}", text):
        raise ReceiptError(f"{label} must be {width} lowercase hex characters (got {value!r})")
    return text


def _surface_infos(values):
    return [idc_matrix_check.normalize_surface(raw) for raw in (values or [])]


def _path_info(path: str):
    return idc_matrix_check.normalize_surface(path)


def _boundary_problems(changed_paths, touch, off_limits):
    touch_infos = _surface_infos(touch)
    off_infos = _surface_infos(off_limits)
    outside = []
    forbidden = []
    for path in sorted(changed_paths):
        info = _path_info(path)
        if not any(idc_matrix_check.surfaces_overlap(info, surface) for surface in touch_infos):
            outside.append(info["normalized"])
        if any(idc_matrix_check.surfaces_overlap(info, surface) for surface in off_infos):
            forbidden.append(info["normalized"])
    return outside, forbidden


def _load_verdict(path: str):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ReceiptError(f"could not read review verdict {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ReceiptError(f"review verdict {path} is invalid JSON: {exc}") from exc
    problems = RV.check(doc)
    if problems:
        raise ReceiptError("review verdict does not validate: " + "; ".join(problems[:3]))
    problem = RV.witness_problem(path, doc)
    if problem:
        raise ReceiptError(problem)
    return doc


def _resolve_receipt_path(repo: str, path: str) -> str:
    repo_root = os.path.abspath(VC._repo_identity(repo))
    abs_path = os.path.realpath(os.path.abspath(path))
    if not abs_path.startswith(repo_root + os.sep) and abs_path != repo_root:
        raise ReceiptError(f"{path} must live under the governed repo root {repo_root}")
    return abs_path


def _rel(repo: str, path: str) -> str:
    return os.path.relpath(os.path.realpath(os.path.abspath(path)), os.path.abspath(VC._repo_identity(repo)))


def write_receipt(*, repo: str, contract_path: str, execution_path: str, verdict_path: str,
                  graph_digest: str, projection_digest: str, out: str):
    workspace = os.path.abspath(repo)
    repo_root = os.path.abspath(VC._repo_identity(workspace))
    contract = VC.load_contract(contract_path)
    execution = VC.load_execution(execution_path)
    verdict = _load_verdict(verdict_path)

    if os.path.abspath(contract.get("repo") or "") != repo_root:
        raise ReceiptError("validation contract is bound to a different repo identity")
    if os.path.abspath(execution.get("repo") or "") != repo_root:
        raise ReceiptError("execution receipt is bound to a different repo identity")
    if contract.get("issue") != execution.get("issue") or contract.get("pr") != execution.get("pr"):
        raise ReceiptError("validation contract and execution receipt disagree on the issue/PR identity")
    if execution.get("contract_digest") != contract.get("contract_digest"):
        raise ReceiptError("execution receipt is not for the frozen validation contract it claims")
    if execution.get("result") != "pass":
        raise ReceiptError("verification run against stale code is refused until the frozen gate records a passing execution")

    graph_digest = _ensure_hex("graph_digest", graph_digest)
    projection_digest = _ensure_hex("projection_digest", projection_digest)
    if graph_digest != contract.get("graph_digest") or projection_digest != contract.get("projection_digest"):
        raise ReceiptError("stale graph/projection evidence refused: the current graph/projection digest no longer matches the frozen validation contract")

    current_head = VC.git_head(workspace)
    current_diff = VC.git_diff_info(workspace, contract["base_commit"], ref="HEAD")
    if execution.get("head") != current_head or execution.get("diff_digest") != current_diff["diff_digest"]:
        raise ReceiptError("verification run against stale code is refused: the execution receipt does not match the current final diff")

    if verdict.get("issue") != contract.get("issue"):
        raise ReceiptError(f"wrong issue refused: review verdict is for issue #{verdict.get('issue')}, not #{contract.get('issue')}")
    if verdict.get("pr") != contract.get("pr"):
        raise ReceiptError(f"wrong PR refused: review verdict is for PR #{verdict.get('pr')}, not #{contract.get('pr')}")
    review_head = str(verdict.get("head") or "").strip()
    review_diff = str(verdict.get("diff_digest") or "").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", review_head):
        raise ReceiptError("review of a different diff is refused: the review verdict is missing a valid 40-hex `head` binding")
    if not re.fullmatch(r"[0-9a-f]{64}", review_diff):
        raise ReceiptError("review of a different diff is refused: the review verdict is missing a valid 64-hex `diff_digest` binding")
    if review_head != current_head or review_diff != current_diff["diff_digest"]:
        raise ReceiptError("review of a different diff is refused: the review verdict does not bind to the current final head/diff")

    outside, forbidden = _boundary_problems(current_diff["changed_paths"], contract.get("touch"), contract.get("off_limits"))
    if forbidden:
        raise ReceiptError("actual path(s) under `off-limits` refused: " + ", ".join(forbidden))
    if outside:
        raise ReceiptError("actual path(s) outside `touch` refused: " + ", ".join(outside))

    out_abs = _resolve_receipt_path(repo_root, out)
    doc = {
        "schema_version": SCHEMA_VERSION,
        "kind": RECEIPT_KIND,
        "written_by": os.path.basename(__file__),
        "created_at": VC._now(),
        "repo": repo_root,
        "issue": contract.get("issue"),
        "pr": contract.get("pr"),
        "graph_node": contract.get("graph_node"),
        "graph_digest": graph_digest,
        "projection_digest": projection_digest,
        "contract_path": _rel(repo, contract_path),
        "contract_digest": contract.get("contract_digest"),
        "execution_path": _rel(repo, execution_path),
        "execution_digest": execution.get("execution_digest"),
        "verdict_path": _rel(repo, verdict_path),
        "verdict_digest": _digest_file(verdict_path),
        "base_commit": contract.get("base_commit"),
        "head": current_head,
        "diff_digest": current_diff["diff_digest"],
        "changed_paths": current_diff["changed_paths"],
        "touch": list(contract.get("touch") or []),
        "off_limits": list(contract.get("off_limits") or []),
        "review_head": review_head,
        "review_diff_digest": review_diff,
        "result": "pass",
    }
    doc["receipt_digest"] = _receipt_digest(doc)
    VC.atomic_write_json(out_abs, doc)
    VC._record_witness("build-receipt", out_abs, doc)
    return doc


def load_receipt(path: str, require_witness: bool = True):
    try:
        doc = _read_json(path)
    except OSError as exc:
        raise ReceiptError(f"could not read build receipt {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ReceiptError(f"build receipt {path} is invalid JSON: {exc}") from exc
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ReceiptError(f"build receipt schema_version must be {SCHEMA_VERSION}, got {doc.get('schema_version')!r}")
    if doc.get("kind") != RECEIPT_KIND:
        raise ReceiptError(f"build receipt kind must be {RECEIPT_KIND!r}, got {doc.get('kind')!r}")
    if doc.get("written_by") != os.path.basename(__file__):
        raise ReceiptError("build receipt must be source-owned by idc_build_receipt.py")
    expected = _receipt_digest(doc)
    if doc.get("receipt_digest") != expected:
        raise ReceiptError("build receipt diff digest mismatch — the recorded implementation receipt was modified after it was written")
    if require_witness:
        problem = VC._witness_problem("build-receipt", path, doc)
        if problem:
            raise ReceiptError(problem)
    return doc


def verify_receipt(*, repo: str, receipt_path: str, expected_issue: int | None = None,
                   expected_pr: int | None = None, head_ref: str | None = None):
    workspace = os.path.abspath(repo)
    repo_root = os.path.abspath(VC._repo_identity(workspace))
    receipt = load_receipt(receipt_path)
    if os.path.abspath(receipt.get("repo") or "") != repo_root:
        raise ReceiptError("build receipt is bound to a different repo identity")
    if expected_issue is not None and int(expected_issue) != int(receipt.get("issue")):
        raise ReceiptError(f"wrong issue refused: build receipt owns issue #{receipt.get('issue')}, not #{expected_issue}")
    if expected_pr is not None and int(expected_pr) != int(receipt.get("pr")):
        raise ReceiptError(f"wrong PR refused: build receipt owns PR #{receipt.get('pr')}, not #{expected_pr}")

    contract_path = os.path.join(repo_root, receipt.get("contract_path"))
    execution_path = os.path.join(repo_root, receipt.get("execution_path"))
    verdict_path = os.path.join(repo_root, receipt.get("verdict_path"))
    contract = VC.load_contract(contract_path)
    execution = VC.load_execution(execution_path)
    verdict = _load_verdict(verdict_path)

    if contract.get("contract_digest") != receipt.get("contract_digest"):
        raise ReceiptError("build receipt references a different frozen validation contract than the file it names")
    if execution.get("execution_digest") != receipt.get("execution_digest"):
        raise ReceiptError("build receipt references a different execution receipt than the file it names")
    if execution.get("result") != "pass":
        raise ReceiptError("caller-authored / forged execution result refused: the named execution receipt is not a passing machine execution")
    if contract.get("issue") != receipt.get("issue") or contract.get("pr") != receipt.get("pr"):
        raise ReceiptError("build receipt issue/PR no longer match the frozen validation contract")
    if execution.get("issue") != receipt.get("issue") or execution.get("pr") != receipt.get("pr"):
        raise ReceiptError("build receipt issue/PR no longer match the execution receipt")

    recomputed = VC.git_diff_info(workspace, receipt.get("base_commit"), ref=receipt.get("head"))
    if recomputed["diff_digest"] != receipt.get("diff_digest"):
        raise ReceiptError("diff digest mismatch refused: the build receipt no longer matches the exact final diff it claims")
    if sorted(recomputed["changed_paths"]) != sorted(receipt.get("changed_paths") or []):
        raise ReceiptError("changed-path set mismatch refused: the build receipt no longer matches the exact final diff it claims")
    outside, forbidden = _boundary_problems(recomputed["changed_paths"], contract.get("touch"), contract.get("off_limits"))
    if forbidden:
        raise ReceiptError("actual path(s) under `off-limits` refused: " + ", ".join(forbidden))
    if outside:
        raise ReceiptError("actual path(s) outside `touch` refused: " + ", ".join(outside))
    if head_ref is not None:
        live_head = VC.git_head(workspace, head_ref)
        if live_head != receipt.get("head"):
            raise ReceiptError("stale build receipt refused: the live review/verification head no longer matches the branch tip being merged")

    if verdict.get("issue") != receipt.get("issue"):
        raise ReceiptError(f"wrong issue refused: review verdict is for issue #{verdict.get('issue')}, not #{receipt.get('issue')}")
    if verdict.get("pr") != receipt.get("pr"):
        raise ReceiptError(f"wrong PR refused: review verdict is for PR #{verdict.get('pr')}, not #{receipt.get('pr')}")
    if str(verdict.get("head") or "") != str(receipt.get("review_head") or ""):
        raise ReceiptError("review of a different diff is refused: the review verdict head no longer matches the implementation receipt")
    if str(verdict.get("diff_digest") or "") != str(receipt.get("review_diff_digest") or ""):
        raise ReceiptError("review of a different diff is refused: the review verdict diff digest no longer matches the implementation receipt")
    if receipt.get("review_head") != receipt.get("head") or receipt.get("review_diff_digest") != receipt.get("diff_digest"):
        raise ReceiptError("review of a different diff is refused: the implementation receipt is not bound to the same head/diff the review approved")
    if receipt.get("graph_digest") != contract.get("graph_digest") or receipt.get("projection_digest") != contract.get("projection_digest"):
        raise ReceiptError("stale graph/projection evidence refused: the implementation receipt no longer matches the frozen planning digests")
    return {
        "ok": True,
        "issue": receipt.get("issue"),
        "pr": receipt.get("pr"),
        "head": receipt.get("head"),
        "diff_digest": receipt.get("diff_digest"),
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description="Write and verify source-owned build receipts.")
    sp = ap.add_subparsers(dest="command", required=True)

    wp = sp.add_parser("write")
    wp.add_argument("--repo", required=True)
    wp.add_argument("--contract", required=True)
    wp.add_argument("--execution", required=True)
    wp.add_argument("--verdict", required=True)
    wp.add_argument("--graph-digest", required=True)
    wp.add_argument("--projection-digest", required=True)
    wp.add_argument("--out", required=True)

    vp = sp.add_parser("verify")
    vp.add_argument("--repo", required=True)
    vp.add_argument("--receipt", required=True)
    vp.add_argument("--issue", type=int)
    vp.add_argument("--pr", type=int)
    vp.add_argument("--head-ref")

    args = ap.parse_args(argv)
    try:
        if args.command == "write":
            doc = write_receipt(
                repo=args.repo,
                contract_path=args.contract,
                execution_path=args.execution,
                verdict_path=args.verdict,
                graph_digest=args.graph_digest,
                projection_digest=args.projection_digest,
                out=args.out,
            )
            json.dump({
                "ok": True,
                "issue": doc.get("issue"),
                "pr": doc.get("pr"),
                "head": doc.get("head"),
                "diff_digest": doc.get("diff_digest"),
            }, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
        if args.command == "verify":
            result = verify_receipt(
                repo=args.repo,
                receipt_path=args.receipt,
                expected_issue=args.issue,
                expected_pr=args.pr,
                head_ref=args.head_ref,
            )
            json.dump(result, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return 0
    except (ReceiptError, VC.ValidationError) as exc:
        die(str(exc), code=2)
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    raise SystemExit(main())
