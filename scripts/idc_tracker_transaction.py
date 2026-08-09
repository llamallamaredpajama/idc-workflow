#!/usr/bin/env python3
"""Sanctioned tracker transaction helper for frozen planning projection apply.

This is the U5 planning transaction path:
  snapshot/digest -> pure simulation -> freeze projection + ordered sanctioned operations ->
  optimistic-concurrency re-read -> obligation before first live write -> sanctioned apply only ->
  mandatory journal corroboration -> exact live postcondition -> planning receipt last.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import idc_journal_replay as RP  # noqa: E402
import idc_planning_receipt as PR  # noqa: E402
import idc_tracker_projection  # noqa: E402
import idc_transition  # noqa: E402

SCHEMA_VERSION = 1


class TransactionError(Exception):
    pass


def die(message: str, code: int = 1):
    sys.stderr.write(f"idc-tracker-transaction: {message}\n")
    sys.exit(code)


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _repo_path(repo: str, path: str) -> str:
    if os.path.isabs(path):
        return path
    return os.path.join(repo, path)


def _rel_if_under_repo(repo: str, path: str) -> str:
    repo_abs = os.path.abspath(repo)
    path_abs = os.path.abspath(path)
    try:
        rel = os.path.relpath(path_abs, repo_abs)
    except ValueError:
        return path
    if rel.startswith(".." + os.sep) or rel == "..":
        return path
    return rel


def _live_rows(backend: str, tracker: str, repo: str, owner: str | None = None,
               project: int | None = None):
    return PR.normalize_live_items(PR.read_live_snapshot(backend, tracker, repo, owner=owner, project=project))


def _bundle_without_digest(bundle: dict) -> dict:
    clone = dict(bundle)
    clone.pop("frozen_digest", None)
    return clone


def _frozen_digest(bundle: dict) -> str:
    return PR.sha256_json(_bundle_without_digest(bundle))


def write_frozen(path: str, bundle: dict):
    body = dict(bundle)
    body["frozen_digest"] = _frozen_digest(body)
    PR.atomic_write_json(path, body)


def load_frozen(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as fh:
            bundle = json.load(fh)
    except OSError as exc:
        raise TransactionError(f"could not read frozen bundle {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise TransactionError(f"frozen bundle {path} is invalid JSON: {exc}")
    if bundle.get("schema_version") != SCHEMA_VERSION:
        raise TransactionError(f"frozen bundle schema_version must be {SCHEMA_VERSION}, got {bundle.get('schema_version')!r}")
    observed = bundle.get("frozen_digest")
    expected = _frozen_digest(bundle)
    if observed != expected:
        raise TransactionError("frozen bundle digest mismatch — the frozen projection/operations were modified after freeze")
    return bundle


# ── github goal-contract body channel (B1) ───────────────────────────────────────────────────────
# The sanctioned create door (idc_transition.run("create-ticket", …, body=X) → idc_gh_board.create_item
# → `gh issue create --body X`) already writes bodies; U5 simply stopped feeding it one. These helpers
# restore create-with-body on the GITHUB backend ONLY (the filesystem backend has no issue bodies — its
# create ops carry no `body` key and stay `body=""`, byte-for-byte unchanged). Marker AUTHORITY stays in
# FIXED CODE (global contract #16): the model authors prose via --bodies; the machine derives + appends
# the provenance marker deterministically from (basename(matrix), logical_id), so a downstream sweep
# (idc_recirc_sweep.provenance_of) / Plan's post-condition (idc_provenance_check.py) matches the issue to
# its matrix pillar by EXACT key — never a fuzzy Trace: match, never a model-writable machine-checked key.


def _provenance_marker(matrix_basename: str, logical_id: str) -> str:
    """The machine-owned github provenance marker for a minted Buildable. Serialized so that
    idc_recirc_sweep.provenance_of (and thus idc_provenance_check.py) accepts it verbatim — the sweep's
    own parser is the authority, so this can never drift from what it will validate."""
    payload = json.dumps({"matrix": matrix_basename, "pillar": logical_id},
                         separators=(",", ":"), ensure_ascii=False)
    return f"<!-- idc-provenance: {payload} -->"


def _compose_body_with_marker(body: str, matrix_basename: str, logical_id: str) -> str:
    """Model-authored prose with the machine-derived marker APPENDED so the minted issue body ENDS with
    the marker (the shape idc_provenance_check re-reads and the sweep matches)."""
    return body.rstrip("\n") + "\n\n" + _provenance_marker(matrix_basename, logical_id)


def _load_bodies(path: str | None) -> dict:
    """Load the optional --bodies map {logical_id: model-authored goal-contract body}. Absent path → {}
    (the github fail-closed guard below then refuses any create with no body)."""
    if not path:
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except OSError as exc:
        raise TransactionError(f"could not read --bodies map {path}: {exc}")
    except json.JSONDecodeError as exc:
        raise TransactionError(f"--bodies map {path} is invalid JSON: {exc}")
    if not isinstance(data, dict):
        raise TransactionError("--bodies map must be a JSON object {logical_id: body}")
    return data


def _attach_github_bodies(operations, matrix_path, bodies):
    """Thread the model-authored goal-contract body + machine-derived provenance marker onto each github
    create-ticket op (github backend only; the frozen op then carries the composed body, covered by
    operations_digest → tamper-evident after freeze). FAIL CLOSED: a create whose logical_id has no body
    entry, or an empty/whitespace body, or a body that ALREADY carries an idc-provenance marker, raises
    TransactionError — no empty-body (and no marker-shadowed) Buildable can be frozen."""
    import idc_recirc_sweep as RS  # lazy: RS imports idc_transition (already loaded) — no module cycle
    matrix_basename = os.path.basename(matrix_path)
    for op in operations:
        if op.get("op") != "create-ticket":
            continue
        logical_id = op["logical_id"]
        body = bodies.get(logical_id)
        if body is None or not str(body).strip():
            raise TransactionError(
                f"github create for {logical_id!r} has no goal-contract body in --bodies — refusing to "
                "freeze an empty-body Buildable (Plan must author one body per created Buildable)")
        if RS.PROVENANCE_MARKER.search(str(body)):
            raise TransactionError(
                f"github create for {logical_id!r}: the authored body already carries an idc-provenance "
                "marker — the machine owns the marker (a model-authored one could shadow the "
                "machine-derived one via provenance_of's first-match); refusing to freeze")
        op["body"] = _compose_body_with_marker(str(body), matrix_basename, logical_id)


def build_operations(projection_rows, start_rows):
    projection_by_id = {row["logical_id"]: row for row in projection_rows}
    start_by_id = {row["logical_id"]: row for row in start_rows}
    operations = []

    create_ids = sorted(logical_id for logical_id in projection_by_id if logical_id not in start_by_id)
    for logical_id in create_ids:
        projected = projection_by_id[logical_id]
        operations.append({
            "op": "create-ticket",
            "logical_id": logical_id,
            "title": projected["title"],
            "stage": projected["stage"],
            "status": projected["status"],
        })

    for logical_id in sorted(projection_by_id):
        projected = projection_by_id[logical_id]
        current = start_by_id.get(logical_id)
        current_blocked = sorted(current.get("blocked_by", [])) if current else []
        projected_blocked = sorted(projected.get("blocked_by", []))
        removed = sorted(set(current_blocked) - set(projected_blocked))
        added = sorted(set(projected_blocked) - set(current_blocked))
        for parent in removed:
            operations.append({
                "op": "unblock",
                "logical_id": logical_id,
                "by_logical_id": parent,
            })
        for parent in added:
            operations.append({
                "op": "link",
                "parent_logical_id": parent,
                "child_logical_id": logical_id,
                "kind": "blocks",
            })

        if current is None:
            for field_name, key in (("Wave", "wave"), ("Phase", "phase"), ("Domain", "domain")):
                value = projected.get(key, "")
                if value != "":
                    operations.append({
                        "op": "set-field",
                        "logical_id": logical_id,
                        "field": field_name,
                        "value": PR.normalize_text(value),
                    })
            continue

        status_changed = PR.normalize_text(current.get("status")) != PR.normalize_text(projected.get("status"))
        stage_changed = PR.normalize_text(current.get("stage")) != PR.normalize_text(projected.get("stage"))
        if stage_changed or (status_changed and not (removed and projected.get("status") == "Todo" and not stage_changed)):
            move = {
                "op": "move",
                "logical_id": logical_id,
                "to_status": PR.normalize_text(projected.get("status")),
            }
            if stage_changed:
                move["to_stage"] = PR.normalize_text(projected.get("stage"))
            operations.append(move)

        for field_name, key in (("Wave", "wave"), ("Phase", "phase"), ("Domain", "domain")):
            if PR.normalize_text(current.get(key)) != PR.normalize_text(projected.get(key)):
                operations.append({
                    "op": "set-field",
                    "logical_id": logical_id,
                    "field": field_name,
                    "value": PR.normalize_text(projected.get(key)),
                })

    return operations


def _filter_relevant(rows, relevant_ids):
    wanted = set(relevant_ids)
    return [row for row in rows if row["logical_id"] in wanted]


def freeze_plan(repo: str, matrix_path: str, backend: str, tracker: str = "TRACKER.md",
                owner: str | None = None, project: int | None = None,
                baseline: str = "expected-red", label: str | None = None,
                bodies_path: str | None = None):
    repo = os.path.abspath(repo)
    tracker_path = _repo_path(repo, tracker)
    projection_bundle = idc_tracker_projection.build_projection(
        matrix_path=matrix_path,
        backend=backend,
        tracker=tracker_path,
        repo=repo,
        owner=owner,
        project=project,
    )
    if projection_bundle.get("simulation", {}).get("mutated_live_tracker"):
        raise TransactionError("pure simulation reported a live tracker mutation")

    start_rows = _live_rows(backend, tracker_path, repo, owner=owner, project=project)
    projection_rows = PR.normalize_projection_rows(projection_bundle.get("projection"))
    relevant_ids = [row["logical_id"] for row in projection_rows]
    relevant_rows = _filter_relevant(start_rows, relevant_ids)
    operations = build_operations(projection_rows, start_rows)
    if backend == "github":
        # Thread the goal-contract body + machine-derived marker onto each github create-ticket op
        # BEFORE the bundle's operations_digest is taken, so the body is tamper-evident after freeze.
        # On the filesystem backend --bodies is ignored (its creates carry no body — see --help).
        _attach_github_bodies(operations, matrix_path, _load_bodies(bodies_path))
    actual = "expected-green" if not operations else "expected-red"
    if baseline not in {"expected-red", "expected-green"}:
        raise TransactionError(f"baseline must be expected-red or expected-green, got {baseline!r}")
    if actual != baseline:
        raise TransactionError(f"unexpected-green baseline refusal: expected {baseline}, actual {actual}")
    if label is None or not str(label).strip():
        label = f"planning-{PR.sha256_json(projection_rows)[:12]}"

    bundle = {
        "schema_version": SCHEMA_VERSION,
        "kind": "planning-transaction",
        "created_at": _now(),
        "repo": repo,
        "backend": backend,
        "tracker": _rel_if_under_repo(repo, tracker_path),
        "owner": owner,
        "project": project,
        "matrix": _rel_if_under_repo(repo, matrix_path),
        "label": label,
        "baseline": {
            "expected": baseline,
            "actual": actual,
            "action_count": len(projection_bundle.get("action_plan") or []),
            "operation_count": len(operations),
        },
        "start_snapshot": start_rows,
        "start_digest": PR.sha256_json(start_rows),
        "relevant_start_snapshot": relevant_rows,
        "relevant_start_digest": PR.sha256_json(relevant_rows),
        "graph_digest": projection_bundle.get("graph_digest"),
        "projection_bundle_digest": projection_bundle.get("projection_digest"),
        "projection": projection_rows,
        "projection_digest": PR.sha256_json(projection_rows),
        "action_plan": projection_bundle.get("action_plan") or [],
        "simulation": projection_bundle.get("simulation") or {},
        "operations": operations,
        "operations_digest": PR.sha256_json(operations),
        "receipt_relpath": PR.receipt_relpath(label),
        "obligation_relpath": PR.obligation_relpath(label),
    }
    bundle["frozen_digest"] = _frozen_digest(bundle)
    return bundle


def _matching_journal_entries(entries, operation, runtime):
    op = operation.get("op")
    item = runtime.get("item")
    if op == "create-ticket":
        return [e for e in entries if e.get("op") == op and RP.journal_item_id(e) == item]
    if op == "set-field":
        return [e for e in entries if e.get("op") == op and RP.journal_item_id(e) == item]
    if op == "move":
        matched = []
        for entry in entries:
            if entry.get("op") != op or RP.journal_item_id(entry) != item:
                continue
            to = entry.get("to") or {}
            if PR.normalize_text(to.get("status")) != PR.normalize_text(operation.get("to_status")):
                continue
            if operation.get("to_stage") is not None and PR.normalize_text(to.get("stage")) != PR.normalize_text(operation.get("to_stage")):
                continue
            matched.append(entry)
        return matched
    if op == "unblock":
        return [
            e for e in entries
            if e.get("op") == op
            and RP.journal_item_id(e) == item
            and PR.normalize_text(e.get("unblocked_by")) == PR.normalize_text(runtime.get("by"))
        ]
    if op == "link":
        return [
            e for e in entries
            if e.get("op") == op
            and PR.normalize_text(e.get("parent")) == PR.normalize_text(runtime.get("parent"))
            and PR.normalize_text(e.get("child")) == PR.normalize_text(runtime.get("child"))
            and PR.normalize_text(e.get("kind")) == PR.normalize_text(operation.get("kind", "blocks"))
        ]
    return []


def _scan_journal(repo: str):
    path = os.path.join(repo, idc_transition.JOURNAL_REL)
    entries, err = RP.scan_journal_strict(path)
    if err:
        raise TransactionError(f"mandatory transaction journal is unreadable: {err}")
    return entries


def _resolve_number(mapping: dict, logical_id: str) -> int:
    if logical_id not in mapping:
        raise TransactionError(f"operation target {logical_id!r} has no live tracker identity")
    return int(mapping[logical_id])


def _execute_operation(ctx: dict, operation: dict, logical_to_number: dict):
    op = operation["op"]
    if op == "create-ticket":
        num = idc_transition.run(
            "create-ticket",
            ctx,
            title=operation["title"],
            body=operation.get("body", ""),
            stage=operation.get("stage") or None,
            status=operation.get("status") or None,
        )
        logical_to_number[operation["logical_id"]] = int(num)
        return {"item": int(num)}
    if op == "set-field":
        num = _resolve_number(logical_to_number, operation["logical_id"])
        idc_transition.run("set-field", ctx, num=num, field=operation["field"], value=operation["value"])
        return {"item": num}
    if op == "move":
        num = _resolve_number(logical_to_number, operation["logical_id"])
        idc_transition.run(
            "move",
            ctx,
            num=num,
            to_status=operation["to_status"],
            to_stage=operation.get("to_stage"),
        )
        return {"item": num}
    if op == "unblock":
        num = _resolve_number(logical_to_number, operation["logical_id"])
        parent = _resolve_number(logical_to_number, operation["by_logical_id"])
        idc_transition.run("unblock", ctx, num=num, to_status="Todo", by=parent)
        return {"item": num, "by": parent}
    if op == "link":
        parent = _resolve_number(logical_to_number, operation["parent_logical_id"])
        child = _resolve_number(logical_to_number, operation["child_logical_id"])
        idc_transition.run("link", ctx, parent=parent, child=child, kind=operation.get("kind", "blocks"))
        return {"parent": parent, "child": child}
    raise TransactionError(f"unknown sanctioned operation {op!r}")


def _obligation_record(bundle: dict, status: str, applied_operations, remaining_operations, failure: str | None = None,
                       final_digest: str | None = None):
    record = {
        "schema_version": SCHEMA_VERSION,
        "kind": "planning-transaction-obligation",
        "created_at": _now(),
        "label": bundle.get("label"),
        "backend": bundle.get("backend"),
        "start_digest": bundle.get("start_digest"),
        "relevant_start_digest": bundle.get("relevant_start_digest"),
        "projection_digest": bundle.get("projection_digest"),
        "operations_digest": bundle.get("operations_digest"),
        "receipt_relpath": bundle.get("receipt_relpath"),
        "status": status,
        "applied_operations": applied_operations,
        "remaining_operations": remaining_operations,
    }
    if failure:
        record["failure"] = failure
    if final_digest is not None:
        record["final_digest"] = final_digest
    return record


def _write_obligation(repo: str, bundle: dict, status: str, applied_operations, remaining_operations,
                      failure: str | None = None, final_digest: str | None = None):
    path = _repo_path(repo, bundle["obligation_relpath"])
    PR.atomic_write_json(path, _obligation_record(bundle, status, applied_operations, remaining_operations,
                                                  failure=failure, final_digest=final_digest))
    return path


def _read_live_issue_body(repo: str, number) -> str:
    """Re-read one github issue's LIVE body — the SAME `gh issue view <n> --json body -q .body` idiom
    idc_provenance_check uses, so the transaction's own post-apply check is parser-compatible with it.
    A gh failure is fail-closed (raises TransactionError): the postcondition can never pass blind."""
    try:
        proc = subprocess.run(["gh", "issue", "view", str(number), "--json", "body", "-q", ".body"],
                              cwd=repo, capture_output=True, text=True)
    except OSError as exc:
        raise TransactionError(f"github body postcondition: gh issue view #{number} failed: {exc}")
    if proc.returncode != 0:
        raise TransactionError(
            f"github body postcondition: gh issue view #{number} exited {proc.returncode}")
    return proc.stdout


def _verify_github_bodies(repo: str, bundle: dict, applied_operations):
    """github-only D3 exact-readback of each minted Buildable's LIVE body: it must carry the
    machine-derived idc-provenance marker naming this run's matrix + the create's pillar id. Uses
    idc_recirc_sweep.provenance_of (the sweep's own parser) so the transaction enforces exactly what
    idc_provenance_check.py checks — that helper in Plan Phase 5 becomes a verification of an
    already-satisfied invariant. Returns the list of misses (empty ⇒ every marker landed)."""
    import idc_recirc_sweep as RS  # lazy: RS imports idc_transition (already loaded) — no module cycle
    matrix_basename = os.path.basename(bundle.get("matrix") or "")
    misses = []
    for applied in applied_operations:
        if applied.get("op") != "create-ticket":
            continue
        logical_id = applied.get("logical_id")
        number = (applied.get("runtime") or {}).get("item")
        prov = RS.provenance_of(_read_live_issue_body(repo, number))
        if not prov or prov.get("matrix") != matrix_basename or prov.get("pillar") != logical_id:
            misses.append(
                f"#{number} ({logical_id}) live body is missing its idc-provenance marker "
                f"(matrix={matrix_basename!r}, pillar={logical_id!r})")
    return misses


# The single-select fields Plan may need new options for. `Status` and `Stage` are NOT here: their
# option sets are the machine's own enums (workflow-machine.yaml), reconciled by their own doors, and
# minting a new one from a plan's data would let a transaction invent a workflow state.
_PRESEED_FIELDS = ("Wave", "Phase", "Domain")


def apply_frozen(frozen_path: str, repo: str | None = None, backend: str | None = None,
                 tracker: str | None = None, owner: str | None = None, project: int | None = None,
                 after_apply_hook=None):
    bundle = load_frozen(frozen_path)
    repo = os.path.abspath(repo or bundle.get("repo") or ".")
    backend = backend or bundle.get("backend")
    tracker_rel = tracker or bundle.get("tracker") or "TRACKER.md"
    tracker_path = _repo_path(repo, tracker_rel)
    owner = owner if owner is not None else bundle.get("owner")
    project = project if project is not None else bundle.get("project")

    current_rows = _live_rows(backend, tracker_path, repo, owner=owner, project=project)
    relevant_current = _filter_relevant(current_rows, [row["logical_id"] for row in bundle.get("projection", [])])
    if PR.sha256_json(relevant_current) != bundle.get("relevant_start_digest"):
        raise TransactionError("relevant tracker state changed since freeze — re-read, re-simulate, and freeze a new projection before apply")

    if backend == "github":
        ctx = idc_transition.github_ctx(repo, owner, project)
    else:
        ctx = idc_transition.fs_ctx(repo, tracker_path)

    logical_to_number = {}
    for row in current_rows:
        ident = row.get("tracker_identity") or ""
        if ident.startswith("#") and ident[1:].isdigit():
            logical_to_number[row["logical_id"]] = int(ident[1:])

    # PRE-SEED the single-select options this transaction is about to set (#208). /idc:init creates
    # `Wave` with exactly one option and `Phase` with one, and nothing ever appends more — so a
    # two-wave plan on a fresh board fails closed at `Wave 2`, as does any domain Plan invents. The
    # frozen transaction already names every value it needs, so the pre-seed is derived from it, never
    # guessed: an option is created only because an operation below is about to set that exact value.
    #
    # Deliberately BEFORE the apply and deliberately FAIL-SOFT. The `set-field` operations keep their
    # own fail-closed refusal for a missing option (pinned honest by PR #207), so a pre-seed that
    # cannot reach the board must not introduce a second failure mode — it reports and lets the
    # existing refusal be the thing that stops the run.
    if backend == "github" and owner and project:
        wanted = {}
        for operation in bundle.get("operations") or []:
            if operation.get("op") == "set-field" and operation.get("field") in _PRESEED_FIELDS:
                value = str(operation.get("value") or "").strip()
                if value:
                    wanted.setdefault(operation["field"], []).append(value)
        if wanted:
            try:
                import idc_stage_options as SO  # noqa: PLC0415 — lazy: only the github path needs it
                appended, problems = SO.ensure_options(repo, owner, project, wanted)
            except Exception as exc:  # noqa: BLE001 — never let pre-seeding break the apply
                appended, problems = [], [f"option pre-seed raised {exc}"]
            for pair in appended:
                sys.stderr.write(f"idc-tracker-transaction: pre-seeded board option {pair}\n")
            for problem in problems:
                sys.stderr.write(f"idc-tracker-transaction: option pre-seed incomplete — {problem} "
                                 "(the set-field refusal below remains the fail-closed gate)\n")

    obligation_path = None
    applied_operations = []
    remaining_operations = list(bundle.get("operations") or [])
    try:
        if remaining_operations:
            obligation_path = _write_obligation(repo, bundle, "pending", applied_operations, remaining_operations)
        for index, operation in enumerate(bundle.get("operations") or []):
            entries_before = _scan_journal(repo)
            runtime = _execute_operation(ctx, operation, logical_to_number)
            entries_after = _scan_journal(repo)
            before_count = len(_matching_journal_entries(entries_before, operation, runtime))
            after_count = len(_matching_journal_entries(entries_after, operation, runtime))
            if after_count <= before_count:
                raise TransactionError(f"mandatory journal append missing for sanctioned operation {operation['op']!r}")
            applied_operations.append({
                **operation,
                "runtime": runtime,
                "journal_count_after": after_count,
            })
            remaining_operations = list(bundle.get("operations") or [])[index + 1:]
            if obligation_path:
                _write_obligation(repo, bundle, "pending", applied_operations, remaining_operations)

        if after_apply_hook is not None:
            after_apply_hook(ctx, bundle)

        final_snapshot = PR.read_live_snapshot(backend, tracker_path, repo, owner=owner, project=project)
        mismatches = PR.compare_projection_to_live(bundle.get("projection"), final_snapshot)
        final_rows = PR.normalize_live_items(final_snapshot)
        final_digest = PR.sha256_json(final_rows)
        if mismatches:
            if obligation_path:
                _write_obligation(repo, bundle, "postcondition-mismatch", applied_operations, [],
                                  failure="; ".join(mismatches), final_digest=final_digest)
            raise TransactionError("exact live postcondition failed: " + "; ".join(mismatches))

        if backend == "github":
            # STRENGTHEN, never weaken (spec §8 D3 extended to the issue body): after the title/stage/
            # status live postcondition passes, prove each minted Buildable's LIVE body carries the
            # machine-derived provenance marker. On a miss, write the postcondition-mismatch obligation
            # and raise — exactly the readback-failure path above; no empty/unmarked Buildable is ever
            # journaled as a clean create + given a receipt.
            marker_misses = _verify_github_bodies(repo, bundle, applied_operations)
            if marker_misses:
                if obligation_path:
                    _write_obligation(repo, bundle, "postcondition-mismatch", applied_operations, [],
                                      failure="; ".join(marker_misses), final_digest=final_digest)
                raise TransactionError(
                    "github body-marker postcondition failed: " + "; ".join(marker_misses))

        if obligation_path:
            _write_obligation(repo, bundle, "awaiting-receipt", applied_operations, [], final_digest=final_digest)
        receipt = PR.build_receipt(repo, bundle, final_snapshot, applied_operations)
        receipt_path = _repo_path(repo, bundle["receipt_relpath"])
        # Write the receipt AND record its out-of-tree machine witness in the git common dir, so a
        # Build contract can prove machine authorship of a borrowed binding without trusting the
        # receipt's own (forgeable) self-digest (F7), and recognizes a receipt written in a linked
        # worktree of the same repo (F19). See idc_planning_receipt.write_receipt.
        PR.write_receipt(repo, receipt_path, receipt)
        return {
            "ok": True,
            "receipt_path": receipt_path,
            "obligation_path": obligation_path,
            "final_digest": receipt["final_digest"],
        }
    except Exception as exc:
        if obligation_path and not isinstance(exc, SystemExit):
            if applied_operations:
                _write_obligation(repo, bundle, "partial-apply", applied_operations, remaining_operations,
                                  failure=str(exc))
        if isinstance(exc, TransactionError):
            raise
        raise TransactionError(str(exc)) from exc


def main():
    ap = argparse.ArgumentParser(description="Freeze and apply sanctioned planning tracker transactions.")
    sp = ap.add_subparsers(dest="command", required=True)

    fp = sp.add_parser("freeze")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--matrix", required=True)
    fp.add_argument("--backend", choices=("filesystem", "github"), required=True)
    fp.add_argument("--tracker", default="TRACKER.md")
    fp.add_argument("--owner")
    fp.add_argument("--project", type=int)
    fp.add_argument("--baseline", required=True, choices=("expected-red", "expected-green"))
    fp.add_argument("--label")
    fp.add_argument("--bodies",
                    help="github backend only: a JSON map {logical_id: model-authored goal-contract "
                         "body}, one entry per Buildable to be created. Fixed code appends the "
                         "machine-derived idc-provenance marker to each; freeze FAILS CLOSED on a "
                         "missing/empty body or a body that already carries a marker. Ignored on the "
                         "filesystem backend (its issues have no bodies).")
    fp.add_argument("--out", required=True)

    ap_apply = sp.add_parser("apply")
    ap_apply.add_argument("--repo", required=True)
    ap_apply.add_argument("--backend", choices=("filesystem", "github"), required=True)
    ap_apply.add_argument("--tracker", default="TRACKER.md")
    ap_apply.add_argument("--owner")
    ap_apply.add_argument("--project", type=int)
    ap_apply.add_argument("--frozen", required=True)

    args = ap.parse_args()
    try:
        if args.command == "freeze":
            bundle = freeze_plan(
                repo=args.repo,
                matrix_path=args.matrix,
                backend=args.backend,
                tracker=args.tracker,
                owner=args.owner,
                project=args.project,
                baseline=args.baseline,
                label=args.label,
                bodies_path=args.bodies,
            )
            write_frozen(args.out, bundle)
            return
        if args.command == "apply":
            result = apply_frozen(
                args.frozen,
                repo=args.repo,
                backend=args.backend,
                tracker=args.tracker,
                owner=args.owner,
                project=args.project,
            )
            json.dump(result, sys.stdout, indent=2, sort_keys=True)
            sys.stdout.write("\n")
            return
    except TransactionError as exc:
        die(str(exc), code=2)
    die(f"unknown command {args.command!r}")


if __name__ == "__main__":
    main()
