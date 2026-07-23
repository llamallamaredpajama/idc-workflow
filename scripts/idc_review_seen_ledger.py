#!/usr/bin/env python3
"""Durable per-PR review seen-fingerprint ledger.

The canonical review → fix → re-review loop needs a fixed-code-owned record of every finding
fingerprint already seen for a PR so resurfaced findings do not file duplicate routed work or recycle
round accounting just because a later round changed their severity/disposition.

This module owns:
  * docs/workflow/code-reviews/pr-<pr>-seen-fingerprints.json

It validates the ledger before every read/write and exposes small helpers that the filer/finisher can
reuse. A malformed direct write is refused fail-closed.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import tempfile
from typing import Any

SCHEMA_VERSION = 1
LEDGER_DIR = os.path.join("docs", "workflow", "code-reviews")
ALLOWED_DISPOSITIONS = {
    "below-floor",
    "confirmed",
    "filed",
    "needs-route",
    "rejected",
    "refuted",
    "suppressed-seen",
}
SUPPRESSED_ROUTE_DISPOSITIONS = {
    "below-floor",
    "confirmed",
    "filed",
    "rejected",
    "refuted",
    "suppressed-seen",
}
ROUTE_RELEVANT_SEVERITIES = {"minor", "nit"}
ROUND_RECORDABLE_DISPOSITIONS = {"below-floor", "confirmed", "rejected", "refuted"}
SEVERITIES = {"blocker", "major", "minor", "nit"}


class ReviewSeenLedgerError(RuntimeError):
    """Malformed or unreadable review seen-ledger state."""


def _utc_now() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat().replace("+00:00", "Z")


def _repo_abspath(repo: str) -> str:
    return os.path.abspath(repo)


def _validate_pr(pr: Any) -> int:
    if not isinstance(pr, int) or isinstance(pr, bool) or pr <= 0:
        raise ReviewSeenLedgerError(f"pr must be a positive integer (got {pr!r})")
    return pr


def ledger_relpath(pr: int) -> str:
    pr = _validate_pr(pr)
    return os.path.join(LEDGER_DIR, f"pr-{pr}-seen-fingerprints.json")


def ledger_path(repo: str, pr: int) -> str:
    return os.path.join(_repo_abspath(repo), ledger_relpath(pr))


def _atomic_write_json(path: str, value: dict[str, Any]) -> None:
    parent = os.path.dirname(os.path.abspath(path))
    os.makedirs(parent, exist_ok=True)
    text = json.dumps(value, indent=2, sort_keys=True) + "\n"
    fd = -1
    tmp = ""
    try:
        fd, tmp = tempfile.mkstemp(prefix=".review-seen-", suffix=".tmp", dir=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
        tmp = ""
    except OSError as exc:
        raise ReviewSeenLedgerError(f"could not write {path}: {exc}") from exc
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
        raise ReviewSeenLedgerError(f"could not read {label}: {exc}") from exc
    if not isinstance(value, dict):
        raise ReviewSeenLedgerError(f"{label} must be a JSON object")
    return value


def _require_nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ReviewSeenLedgerError(f"{label} must be a non-empty string")
    return value.strip()


def _require_timestamp(value: Any, label: str) -> str:
    return _require_nonempty_string(value, label)


def _validate_disposition(value: Any, label: str) -> str:
    disp = _require_nonempty_string(value, label)
    if disp not in ALLOWED_DISPOSITIONS:
        raise ReviewSeenLedgerError(f"{label} must be one of {sorted(ALLOWED_DISPOSITIONS)} (got {disp!r})")
    return disp


def _validate_entry(entry: Any, *, index: int) -> dict[str, Any]:
    if not isinstance(entry, dict):
        raise ReviewSeenLedgerError(f"review seen ledger entry[{index}] is not a JSON object")
    fingerprint = _require_nonempty_string(entry.get("fingerprint"), f"review seen ledger entry[{index}] fingerprint")
    seen_count = entry.get("seen_count")
    if not isinstance(seen_count, int) or isinstance(seen_count, bool) or seen_count < 1:
        raise ReviewSeenLedgerError(f"review seen ledger entry[{index}] seen_count must be an integer >= 1")
    first_seen_at = _require_timestamp(entry.get("first_seen_at"), f"review seen ledger entry[{index}] first_seen_at")
    last_seen_at = _require_timestamp(entry.get("last_seen_at"), f"review seen ledger entry[{index}] last_seen_at")
    last_disposition = _validate_disposition(entry.get("last_disposition"),
                                             f"review seen ledger entry[{index}] last_disposition")
    dispositions = entry.get("dispositions")
    if not isinstance(dispositions, list) or not dispositions:
        raise ReviewSeenLedgerError(f"review seen ledger entry[{index}] dispositions must be a non-empty list")
    cleaned_dispositions = []
    for disp in dispositions:
        cleaned_dispositions.append(_validate_disposition(disp, f"review seen ledger entry[{index}] dispositions[]"))
    if last_disposition not in cleaned_dispositions:
        raise ReviewSeenLedgerError(
            f"review seen ledger entry[{index}] last_disposition must appear in dispositions")
    out = {
        "fingerprint": fingerprint,
        "seen_count": seen_count,
        "first_seen_at": first_seen_at,
        "last_seen_at": last_seen_at,
        "last_disposition": last_disposition,
        "dispositions": sorted(set(cleaned_dispositions)),
    }
    if entry.get("last_dimension") is not None:
        out["last_dimension"] = _require_nonempty_string(
            entry.get("last_dimension"), f"review seen ledger entry[{index}] last_dimension")
    if entry.get("last_severity") is not None:
        severity = _require_nonempty_string(entry.get("last_severity"),
                                            f"review seen ledger entry[{index}] last_severity")
        if severity not in SEVERITIES:
            raise ReviewSeenLedgerError(
                f"review seen ledger entry[{index}] last_severity must be one of {sorted(SEVERITIES)}")
        out["last_severity"] = severity
    if entry.get("last_confidence") is not None:
        confidence = entry.get("last_confidence")
        if not isinstance(confidence, (int, float)) or confidence < 0 or confidence > 1:
            raise ReviewSeenLedgerError(
                f"review seen ledger entry[{index}] last_confidence must be a number in [0, 1]")
        out["last_confidence"] = float(confidence)
    return out


def _validate_ledger(doc: dict[str, Any], *, expected_pr: int | None = None) -> dict[str, Any]:
    if doc.get("schema_version") != SCHEMA_VERSION:
        raise ReviewSeenLedgerError("review seen ledger schema_version must be 1")
    pr = _validate_pr(doc.get("pr"))
    if expected_pr is not None and pr != expected_pr:
        raise ReviewSeenLedgerError(f"review seen ledger is for pr={pr}, not pr={expected_pr}")
    entries = doc.get("entries")
    if not isinstance(entries, list):
        raise ReviewSeenLedgerError("review seen ledger entries must be a list")
    seen = set()
    normalized_entries = []
    for index, entry in enumerate(entries):
        validated = _validate_entry(entry, index=index)
        fingerprint = validated["fingerprint"]
        if fingerprint in seen:
            raise ReviewSeenLedgerError(f"review seen ledger has duplicate fingerprint {fingerprint!r}")
        seen.add(fingerprint)
        normalized_entries.append(validated)
    updated_at = doc.get("updated_at")
    if updated_at is not None:
        updated_at = _require_timestamp(updated_at, "review seen ledger updated_at")
    return {
        "schema_version": SCHEMA_VERSION,
        "pr": pr,
        "entries": normalized_entries,
        "updated_at": updated_at or _utc_now(),
    }


def empty_ledger(pr: int) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "pr": _validate_pr(pr),
        "entries": [],
        "updated_at": _utc_now(),
    }


def read_ledger(repo: str, pr: int) -> dict[str, Any] | None:
    pr = _validate_pr(pr)
    value = _read_json(ledger_path(repo, pr), "review seen ledger")
    return None if value is None else _validate_ledger(value, expected_pr=pr)


def write_ledger(repo: str, doc: dict[str, Any]) -> dict[str, Any]:
    validated = _validate_ledger(dict(doc), expected_pr=_validate_pr(doc.get("pr")))
    validated["entries"] = sorted(validated["entries"], key=lambda entry: entry["fingerprint"])
    validated["updated_at"] = _utc_now()
    _atomic_write_json(ledger_path(repo, validated["pr"]), validated)
    return validated


def _entry_map(doc: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {entry["fingerprint"]: dict(entry) for entry in doc.get("entries") or []}


def _upsert_entry(
    entry_map: dict[str, dict[str, Any]],
    *,
    fingerprint: str,
    disposition: str,
    dimension: str | None = None,
    severity: str | None = None,
    confidence: float | None = None,
) -> dict[str, Any]:
    disposition = _validate_disposition(disposition, "disposition")
    fingerprint = _require_nonempty_string(fingerprint, "fingerprint")
    now = _utc_now()
    current = dict(entry_map.get(fingerprint) or {})
    if current:
        current["seen_count"] = int(current.get("seen_count") or 0) + 1
        current["last_seen_at"] = now
        current["last_disposition"] = disposition
        current["dispositions"] = sorted(set(current.get("dispositions") or []) | {disposition})
    else:
        current = {
            "fingerprint": fingerprint,
            "seen_count": 1,
            "first_seen_at": now,
            "last_seen_at": now,
            "last_disposition": disposition,
            "dispositions": [disposition],
        }
    if dimension is not None:
        current["last_dimension"] = _require_nonempty_string(dimension, "dimension")
    if severity is not None:
        severity = _require_nonempty_string(severity, "severity")
        if severity not in SEVERITIES:
            raise ReviewSeenLedgerError(f"severity must be one of {sorted(SEVERITIES)}")
        current["last_severity"] = severity
    if confidence is not None:
        if not isinstance(confidence, (int, float)) or confidence < 0 or confidence > 1:
            raise ReviewSeenLedgerError("confidence must be a number in [0, 1]")
        current["last_confidence"] = float(confidence)
    entry_map[fingerprint] = current
    return current


def _findings_of(verdict: dict[str, Any]) -> list[dict[str, Any]]:
    findings = verdict.get("findings")
    return findings if isinstance(findings, list) else []


def pr_from_verdict(verdict: dict[str, Any]) -> int | None:
    pr = verdict.get("pr")
    if pr is None:
        return None
    return _validate_pr(pr)


def plan_verdict_round(repo: str, verdict: dict[str, Any]) -> dict[str, Any] | None:
    pr = pr_from_verdict(verdict)
    if pr is None:
        return None
    ledger = read_ledger(repo, pr) or empty_ledger(pr)
    preexisting = _entry_map(ledger)
    route_required = set()
    seen_before = {}
    for finding in _findings_of(verdict):
        if not isinstance(finding, dict):
            continue
        fingerprint = _require_nonempty_string(finding.get("fingerprint"), "verdict fingerprint")
        severity = _require_nonempty_string(finding.get("severity"), "verdict severity")
        pre_seen = fingerprint in preexisting
        seen_before[fingerprint] = pre_seen
        if severity in ROUTE_RELEVANT_SEVERITIES and not pre_seen:
            route_required.add(fingerprint)
    return {
        "pr": pr,
        "ledger": ledger,
        "preexisting": preexisting,
        "seen_before": seen_before,
        "route_required": route_required,
    }


def route_required_for_fingerprint(plan: dict[str, Any] | None, fingerprint: str) -> bool:
    if not plan:
        return True
    return fingerprint in set(plan.get("route_required") or set())


def finalize_verdict_round(repo: str, verdict: dict[str, Any], plan: dict[str, Any] | None,
                           *, filed_fingerprints: set[str] | None = None) -> dict[str, Any] | None:
    if not plan:
        return None
    filed_fingerprints = set(filed_fingerprints or set())
    pr = plan["pr"]
    ledger = dict(plan["ledger"])
    entry_map = _entry_map(ledger)
    for finding in _findings_of(verdict):
        if not isinstance(finding, dict):
            continue
        fingerprint = _require_nonempty_string(finding.get("fingerprint"), "verdict fingerprint")
        dimension = _require_nonempty_string(finding.get("dimension"), "verdict dimension")
        severity = _require_nonempty_string(finding.get("severity"), "verdict severity")
        confidence = finding.get("confidence")
        if severity in ROUTE_RELEVANT_SEVERITIES:
            if fingerprint in filed_fingerprints:
                disposition = "filed"
            elif bool(plan["seen_before"].get(fingerprint)):
                disposition = "suppressed-seen"
            else:
                disposition = "needs-route"
        else:
            disposition = "confirmed"
        _upsert_entry(
            entry_map,
            fingerprint=fingerprint,
            disposition=disposition,
            dimension=dimension,
            severity=severity,
            confidence=float(confidence) if isinstance(confidence, (int, float)) else None,
        )
    ledger["entries"] = sorted(entry_map.values(), key=lambda entry: entry["fingerprint"])
    ledger["updated_at"] = _utc_now()
    return write_ledger(repo, ledger)


def filter_missing_routing_gaps(repo: str, verdict: dict[str, Any], missing_items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    pr = pr_from_verdict(verdict)
    if pr is None:
        return list(missing_items)
    ledger = read_ledger(repo, pr)
    if ledger is None:
        return list(missing_items)
    by_fp = _entry_map(ledger)
    gaps = []
    for item in missing_items:
        if item.get("kind") != "finding":
            gaps.append(item)
            continue
        fingerprint = str(item.get("key", "")).replace("finding:", "", 1)
        entry = by_fp.get(fingerprint)
        if entry and entry.get("last_disposition") in SUPPRESSED_ROUTE_DISPOSITIONS:
            continue
        gaps.append(item)
    return gaps


def _validate_round_candidate(candidate: Any, *, index: int) -> dict[str, Any]:
    if not isinstance(candidate, dict):
        raise ReviewSeenLedgerError(f"round candidate[{index}] is not a JSON object")
    fingerprint = _require_nonempty_string(candidate.get("fingerprint"), f"round candidate[{index}] fingerprint")
    dimension = _require_nonempty_string(candidate.get("dimension"), f"round candidate[{index}] dimension")
    disposition = _validate_disposition(candidate.get("disposition"), f"round candidate[{index}] disposition")
    if disposition not in ROUND_RECORDABLE_DISPOSITIONS:
        raise ReviewSeenLedgerError(
            f"round candidate[{index}] disposition must be one of {sorted(ROUND_RECORDABLE_DISPOSITIONS)}")
    confidence = candidate.get("confidence")
    if not isinstance(confidence, (int, float)) or confidence < 0 or confidence > 1:
        raise ReviewSeenLedgerError(f"round candidate[{index}] confidence must be a number in [0, 1]")
    return {
        "fingerprint": fingerprint,
        "dimension": dimension,
        "disposition": disposition,
        "confidence": float(confidence),
    }


def record_round(repo: str, round_doc: dict[str, Any]) -> dict[str, Any]:
    if round_doc.get("schema_version") != SCHEMA_VERSION:
        raise ReviewSeenLedgerError("round document schema_version must be 1")
    pr = _validate_pr(round_doc.get("pr"))
    candidates = round_doc.get("candidates")
    if not isinstance(candidates, list):
        raise ReviewSeenLedgerError("round document candidates must be a list")
    ledger = read_ledger(repo, pr) or empty_ledger(pr)
    entry_map = _entry_map(ledger)
    for index, candidate in enumerate(candidates):
        validated = _validate_round_candidate(candidate, index=index)
        _upsert_entry(
            entry_map,
            fingerprint=validated["fingerprint"],
            disposition=validated["disposition"],
            dimension=validated["dimension"],
            confidence=validated["confidence"],
        )
    ledger["entries"] = sorted(entry_map.values(), key=lambda entry: entry["fingerprint"])
    ledger["updated_at"] = _utc_now()
    return write_ledger(repo, ledger)


def _cmd_record_round(args: argparse.Namespace) -> int:
    try:
        with open(args.round, encoding="utf-8") as handle:
            round_doc = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ReviewSeenLedgerError(f"could not read round document: {exc}") from exc
    written = record_round(args.repo, round_doc)
    print(json.dumps({
        "pr": written["pr"],
        "ledger": ledger_relpath(written["pr"]),
        "recorded": len(written.get("entries") or []),
    }, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record-round", help="record a validated raw review round into the durable seen ledger")
    record.add_argument("--repo", required=True)
    record.add_argument("--round", required=True)
    record.set_defaults(func=_cmd_record_round)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return int(args.func(args))
    except ReviewSeenLedgerError as exc:
        print(f"idc-review-seen-ledger: {exc}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
