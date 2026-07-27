#!/usr/bin/env python3
"""Planning-application receipt helper for sanctioned tracker transactions.

Writes and verifies the machine-owned receipt emitted after a frozen planning projection is applied,
journaled, read back exactly, and proven live.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

SCHEMA_VERSION = 1
KIND = "planning-application"
WRITTEN_BY = "idc_planning_receipt.py"

# The fields that make a receipt self-describing. A downstream consumer must be able to prove a
# receipt's integrity WITHOUT the live board (which legitimately advances after the receipt is
# written), so these — plus the recomputed self-digest and the machine writer — are the integrity
# surface.
_SELF_REQUIRED = (
    "schema_version", "kind", "written_by", "receipt_digest",
    "projection", "projection_digest", "operations", "operations_digest",
    "final_snapshot", "final_digest", "readback", "obligation_relpath",
)


class ReceiptError(Exception):
    pass


def die(message: str, code: int = 1):
    sys.stderr.write(f"idc-planning-receipt: {message}\n")
    sys.exit(code)


def sha256_json(value) -> str:
    blob = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def normalize_text(value) -> str:
    if value is None:
        return ""
    return str(value)


def _tracker_identity(number) -> str:
    return f"#{number}" if number is not None else ""


def normalize_projection_rows(rows):
    normalized = []
    for row in rows or []:
        normalized.append({
            "logical_id": normalize_text(row.get("logical_id")),
            "title": normalize_text(row.get("logical_id") or row.get("title")),
            "stage": normalize_text(row.get("stage")),
            "status": normalize_text(row.get("status")),
            "wave": normalize_text(row.get("wave")),
            "phase": normalize_text(row.get("phase")),
            "domain": normalize_text(row.get("domain")),
            "blocked_by": sorted(normalize_text(v) for v in row.get("blocked_by", [])),
        })
    return sorted(normalized, key=lambda row: row["logical_id"])


def normalize_live_items(raw_items):
    normalized = []
    for item in raw_items or []:
        title = normalize_text(item.get("title"))
        normalized.append({
            "logical_id": title,
            "tracker_identity": _tracker_identity(item.get("number")),
            "title": title,
            "stage": normalize_text(item.get("stage") or "Buildable"),
            "status": normalize_text(item.get("status")),
            "wave": normalize_text(item.get("wave")),
            "phase": normalize_text(item.get("phase")),
            "domain": normalize_text(item.get("domain")),
            "blocked_by": sorted(normalize_text(v) for v in item.get("blocked_by", [])),
        })
    return sorted(normalized, key=lambda row: row["logical_id"])


def snapshot_digest(rows) -> str:
    return sha256_json(normalize_live_items(rows))


def normalize_receipted_live_rows(rows):
    normalized = []
    for row in rows or []:
        normalized.append({
            "logical_id": normalize_text(row.get("logical_id") or row.get("title")),
            "tracker_identity": normalize_text(row.get("tracker_identity")),
            "title": normalize_text(row.get("title") or row.get("logical_id")),
            "stage": normalize_text(row.get("stage") or "Buildable"),
            "status": normalize_text(row.get("status")),
            "wave": normalize_text(row.get("wave")),
            "phase": normalize_text(row.get("phase")),
            "domain": normalize_text(row.get("domain")),
            "blocked_by": sorted(normalize_text(v) for v in row.get("blocked_by", [])),
        })
    return sorted(normalized, key=lambda row: row["logical_id"])


def receipt_relpath(label: str) -> str:
    safe = (label or "planning").strip().replace(os.sep, "-")
    return os.path.join("docs", "workflow", "planning-receipts", f"{safe}.json")


def obligation_relpath(label: str) -> str:
    safe = (label or "planning").strip().replace(os.sep, "-")
    return os.path.join("docs", "workflow", "planning-obligations", f"{safe}.json")


def atomic_write_json(path: str, data):
    parent = os.path.dirname(os.path.abspath(path)) or "."
    os.makedirs(parent, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".planning-receipt-", suffix=".tmp", dir=parent)
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


def _read_json(path: str):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def _has_git_metadata(path: str) -> bool:
    """True if `path` or an ancestor carries a `.git` entry. A PURE FILESYSTEM check that never invokes
    the git binary, so a missing/broken `git` inside a real repository is not mistaken for a non-git
    repo (which would silently leave the receipt un-anchored — F25). `.git` may be a directory (a normal
    checkout) or a file (a linked worktree), so `os.path.lexists` covers both."""
    current = os.path.abspath(path)
    while True:
        if os.path.lexists(os.path.join(current, ".git")):
            return True
        parent = os.path.dirname(current)
        if parent == current:
            return False
        current = parent


def write_receipt(repo: str, receipt_path: str, receipt: dict) -> None:
    """Write the planning receipt to disk AND record its machine-owned witness in the git common dir.

    The self `receipt_digest` is only tamper-EVIDENCE: it is recomputed over the receipt body, so a
    repo-local forger can swap a borrowed binding (graph/projection digest) and re-sign the receipt,
    and it would still pass `verify_receipt_integrity`. The authoritative proof of machine authorship —
    within the committed-tree (PR) threat model — is an OUT-OF-TREE witness recorded here: the SAME
    git-common-dir witness store the build contract / execution / build receipts use. It records the
    receipt file's byte digest OUTSIDE the committed working tree a PR can edit, so a re-signed forgery
    in a PR has no matching witness; a local actor with `.git` write access could still forge it (that
    is outside the PR threat model, and is scoped in the CHANGELOG). Because the common dir is shared
    across linked worktrees, the witness is visible to a Build contract frozen in any worktree of the
    same repo. A Build freeze refuses to borrow a receipt whose witness is absent or stale, which closes
    the re-signed-forgery hole (F7) while accepting legitimate worktree-produced receipts (F19).

    Anchoring is REQUIRED whenever the repo carries git metadata (a `.git` entry here or in an ancestor,
    detected WITHOUT invoking git). If it does and the witness cannot be recorded — the sanctioned
    validation module is unimportable (a broken install), or `git` is missing/failing — the failure is
    SURFACED here rather than swallowed: otherwise the receipt would persist witness-less and a later
    Build freeze would refuse it with a confusing 'no witness' error far from the real cause (F25).
    Witnessing is skipped ONLY for a genuinely non-git governed repo (the filesystem backend), which has
    no common dir to anchor into and can never reach a Build freeze (freeze itself requires git), so no
    borrow is left unanchored.

    The disk write and the witness record are ONE critical section (F54): the replacement is handed to
    `record_planning_witness` as a callable and performed under the witness-store lock, so a second
    same-label writer cannot replace the receipt between this writer's replace and its witness. Written
    outside the lock, a racer that overwrote the file and then died before witnessing left the final
    on-disk bytes unwitnessed, and a later Build refused a Plan that had reported success."""
    anchor_required = _has_git_metadata(repo)
    # The receipt's parent directory must exist BEFORE the witness context is resolved: that resolution
    # runs `git -C <receipt dir>`, which fails on a missing directory. The write used to create it as a
    # side effect, but the write now happens inside the witness lock (F54), so create it here. Making a
    # directory is not the atomic replace the lock exists to serialize, so it is safe outside.
    parent = os.path.dirname(os.path.abspath(receipt_path))
    if parent:
        os.makedirs(parent, exist_ok=True)

    def _write() -> None:
        atomic_write_json(receipt_path, receipt)

    try:
        import idc_validation_contract as VC  # noqa: E402 — sibling; lazy to avoid an import cycle
    except ImportError as exc:
        if anchor_required:
            raise ReceiptError(
                "could not anchor the planning receipt witness — idc_validation_contract is not "
                f"importable (broken install): {exc}") from exc
        _write()          # non-git governed repo: no witness store to coordinate with
        return
    try:
        VC.record_planning_witness(os.path.abspath(receipt_path), receipt, write_receipt=_write)
    except (VC.ValidationError, OSError) as exc:
        # In a git repo any anchor failure (a non-git ValidationError from a broken common dir, or a
        # raw OSError when `git` is missing) leaves an un-borrowable receipt, so it is surfaced. A
        # genuinely non-git repo (no metadata) legitimately has nothing to anchor into — skip, but
        # still persist the receipt: the anchoring path owns the write now (F54), and this branch may
        # be reached before it ran. `atomic_write_json` is idempotent, so a re-write is harmless.
        if anchor_required:
            raise ReceiptError(f"could not anchor the planning receipt witness: {exc}") from exc
        _write()


def read_live_snapshot(backend: str, tracker: str, repo: str, owner: str | None = None,
                       project: int | None = None):
    if backend == "filesystem":
        import idc_tracker_fs  # noqa: E402
        state = idc_tracker_fs.load(tracker)
        title_by_number = {int(it.get("number")): normalize_text(it.get("title")) for it in state.get("issues", [])
                           if it.get("number") is not None}
        raw = []
        for item in sorted(state.get("issues", []), key=lambda row: row.get("number", 0)):
            blocked = []
            for parent in item.get("blocked_by", []) or []:
                if parent in title_by_number:
                    blocked.append(title_by_number[parent])
                else:
                    blocked.append(f"#{parent}")
            raw.append({
                "number": item.get("number"),
                "title": item.get("title", ""),
                "stage": item.get("stage") or "Buildable",
                "status": item.get("status") or "",
                "wave": item.get("wave") or "",
                "phase": item.get("phase") or "",
                "domain": item.get("domain") or "",
                "blocked_by": blocked,
            })
        return raw
    if backend == "github":
        if not owner or not project:
            raise ReceiptError("github receipt verification requires --owner and --project")
        import idc_gh_board  # noqa: E402
        fetched = idc_gh_board.fetch_items(owner, project, repo)
        title_by_number = {
            int((item.get("content") or {}).get("number")): normalize_text(item.get("title"))
            for item in fetched
            if (item.get("content") or {}).get("number") is not None
        }
        raw = []
        for item in fetched:
            content = item.get("content") or {}
            number = content.get("number")
            blocked = []
            if number is not None:
                for parent in idc_gh_board.blocked_by_numbers(number, repo):
                    blocked.append(title_by_number.get(parent, f"#{parent}"))
            raw.append({
                "number": number,
                "title": item.get("title", ""),
                "stage": item.get("stage") or "Buildable",
                "status": item.get("status") or "",
                "wave": item.get("wave") or "",
                "phase": item.get("phase") or "",
                "domain": item.get("domain") or "",
                "blocked_by": blocked,
            })
        return raw
    raise ReceiptError(f"unknown backend {backend!r}")


def compare_projection_to_live(projection, live_snapshot):
    projection_rows = normalize_projection_rows(projection)
    live_rows = normalize_live_items(live_snapshot)
    projected = {row["logical_id"]: row for row in projection_rows}
    live = {row["logical_id"]: row for row in live_rows}
    mismatches = []

    for logical_id, expected in projected.items():
        observed = live.get(logical_id)
        if observed is None:
            mismatches.append(f"missing projected item {logical_id!r}")
            continue
        if not observed.get("tracker_identity"):
            mismatches.append(f"projected item {logical_id!r} has no concrete tracker identity")
        for field in ("stage", "status", "wave", "phase", "domain"):
            if normalize_text(observed.get(field)) != normalize_text(expected.get(field)):
                mismatches.append(
                    f"{logical_id!r} {field} live={observed.get(field)!r} projected={expected.get(field)!r}"
                )
        if sorted(observed.get("blocked_by", [])) != sorted(expected.get("blocked_by", [])):
            mismatches.append(
                f"{logical_id!r} blocked_by live={sorted(observed.get('blocked_by', []))!r} "
                f"projected={sorted(expected.get('blocked_by', []))!r}"
            )

    projection_phases = {row.get("phase") for row in projection_rows if row.get("phase")}
    for logical_id, observed in live.items():
        if logical_id in projected:
            continue
        if observed.get("stage") != "Buildable":
            continue
        if observed.get("status") not in {"Todo", "Blocked", "In Progress"}:
            continue
        if projection_phases and observed.get("phase") not in projection_phases:
            continue
        mismatches.append(f"unexpected live planning-horizon item {logical_id!r} outside the frozen projection")

    return mismatches


def build_receipt(repo: str, bundle: dict, final_snapshot, applied_operations):
    receipt = {
        "schema_version": SCHEMA_VERSION,
        "kind": KIND,
        "written_by": "idc_planning_receipt.py",
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "repo": os.path.abspath(repo),
        "backend": bundle.get("backend"),
        "label": bundle.get("label"),
        "start_digest": bundle.get("start_digest"),
        "relevant_start_digest": bundle.get("relevant_start_digest"),
        "graph_digest": bundle.get("graph_digest"),
        "projection_bundle_digest": bundle.get("projection_bundle_digest"),
        "projection_digest": bundle.get("projection_digest"),
        "operations_digest": bundle.get("operations_digest"),
        "projection": normalize_projection_rows(bundle.get("projection")),
        "operations": bundle.get("operations") or [],
        "applied_operations": applied_operations or [],
        "obligation_relpath": bundle.get("obligation_relpath"),
        "final_snapshot": normalize_live_items(final_snapshot),
    }
    receipt["final_digest"] = sha256_json(receipt["final_snapshot"])
    receipt["readback"] = {
        "ok": True,
        "mismatches": [],
        "final_digest": receipt["final_digest"],
    }
    body = dict(receipt)
    receipt["receipt_digest"] = sha256_json(body)
    return receipt


def _recompute_receipt_digest(receipt: dict) -> str:
    """The self-digest a fresh receipt commits to: sha256 of every field except the digest itself."""
    body = dict(receipt)
    body.pop("receipt_digest", None)
    return sha256_json(body)


def verify_receipt_integrity(receipt: dict) -> dict:
    """Self-integrity of a planning receipt, WITHOUT reading the live board.

    Proves machine ownership and that nothing was edited after the receipt was written: the machine
    `written_by`, the recomputed self-digest, and the internal projection/operations/final digests.
    A hand-forged or edited receipt that still *matches* the current board is refused here, because
    the `receipt_digest` is recomputed over the whole body (F5), and any borrowed binding (graph /
    projection / final digest) a downstream Build contract copies is covered by that digest (F7).

    The live-board readback is deliberately NOT part of this: the board legitimately advances between
    Plan (when the receipt is written) and Build (when a contract borrows a binding), so a consumer
    that only needs to trust the receipt's own fields must not re-compare against a moved board.
    `verify_receipt` layers the live readback on top for Plan closeout. Returns the normalized
    projection / final snapshot so callers need not re-normalize."""
    if not isinstance(receipt, dict):
        raise ReceiptError("planning receipt is not a JSON object")
    missing = [key for key in _SELF_REQUIRED if key not in receipt]
    if missing:
        raise ReceiptError(f"receipt missing required field(s): {', '.join(missing)}")
    if receipt.get("schema_version") != SCHEMA_VERSION:
        raise ReceiptError(f"receipt schema_version must be {SCHEMA_VERSION}, got {receipt.get('schema_version')!r}")
    if receipt.get("kind") != KIND:
        raise ReceiptError(f"receipt kind must be {KIND!r}, got {receipt.get('kind')!r}")
    if receipt.get("written_by") != WRITTEN_BY:
        raise ReceiptError(
            f"receipt is not machine-owned: written_by must be {WRITTEN_BY!r}, got {receipt.get('written_by')!r}")
    if _recompute_receipt_digest(receipt) != receipt.get("receipt_digest"):
        raise ReceiptError(
            "receipt_digest mismatch — the receipt was edited or hand-forged after it was written")
    projection = normalize_projection_rows(receipt.get("projection"))
    if sha256_json(projection) != receipt.get("projection_digest"):
        raise ReceiptError("receipt projection digest does not match its embedded frozen projection")
    operations = receipt.get("operations") or []
    if sha256_json(operations) != receipt.get("operations_digest"):
        raise ReceiptError("receipt operations digest does not match its embedded ordered operations")
    final_snapshot = normalize_receipted_live_rows(receipt.get("final_snapshot"))
    if sha256_json(final_snapshot) != receipt.get("final_digest"):
        raise ReceiptError("receipt final digest does not match its embedded final live snapshot")
    return {"projection": projection, "final_snapshot": final_snapshot}


def verify_receipt(repo: str, receipt_path: str, backend: str, tracker: str,
                   owner: str | None = None, project: int | None = None):
    try:
        receipt = _read_json(receipt_path)
    except OSError as exc:
        raise ReceiptError(f"could not read receipt {receipt_path}: {exc}")
    except json.JSONDecodeError as exc:
        raise ReceiptError(f"receipt {receipt_path} is invalid JSON: {exc}")

    projection = verify_receipt_integrity(receipt)["projection"]

    live_snapshot = read_live_snapshot(backend, tracker, repo, owner=owner, project=project)
    live_rows = normalize_live_items(live_snapshot)
    live_digest = sha256_json(live_rows)
    if live_digest != receipt.get("final_digest"):
        raise ReceiptError(
            f"receipt final digest mismatch: live board digest {live_digest} != receipt {receipt.get('final_digest')}"
        )
    mismatches = compare_projection_to_live(projection, live_snapshot)
    if mismatches:
        raise ReceiptError("receipt live readback no longer matches the frozen projection: " + "; ".join(mismatches))
    return {
        "ok": True,
        "receipt_path": receipt_path,
        "final_digest": live_digest,
        "projection_digest": receipt.get("projection_digest"),
    }


def main():
    ap = argparse.ArgumentParser(description="Verify planning-application receipts against the live tracker.")
    sp = ap.add_subparsers(dest="command", required=True)

    vp = sp.add_parser("verify")
    vp.add_argument("--repo", required=True)
    vp.add_argument("--receipt", required=True)
    vp.add_argument("--backend", choices=("filesystem", "github"), required=True)
    vp.add_argument("--tracker", default="TRACKER.md")
    vp.add_argument("--owner")
    vp.add_argument("--project", type=int)

    args = ap.parse_args()
    if args.command == "verify":
        try:
            result = verify_receipt(
                repo=args.repo,
                receipt_path=args.receipt,
                backend=args.backend,
                tracker=args.tracker,
                owner=args.owner,
                project=args.project,
            )
        except ReceiptError as exc:
            die(str(exc), code=2)
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    main()
