#!/usr/bin/env python3
"""idc_command_contract.py — the universal IDC command lifecycle contract (Task 2, command integrity).

A governed `/idc:*` command is an OBLIGATION: it is ENTERED (a lifecycle record opens in the session
ledger) and it must be CLOSED with a valid terminal status. This module is the runtime-neutral façade
over that contract — the same validation and the same single ledger write door whether the caller is a
Claude hook, a command's markdown tail, Codex, or Pi. It owns three responsibilities:

  * `start`  — open (idempotently upsert) the command's active record, AFTER a Task-1 freshness check:
               a stale plugin runtime must never open a record (exit 4, no write), because a stale
               command body would record an obligation it cannot honestly discharge.
  * `finish` — close an existing active record owned by this session with a validated terminal status
               + evidence envelope. Rejects an unknown command/status, malformed JSON, an invalid
               envelope, a missing active record, or a foreign session.
  * `status` — read the session's active + finished command records (for the Stop closeout gate's
               human remediation and for tests).

There is DELIBERATELY no `abort-stale` / erase op: an agent cannot make an obligation disappear
without a valid terminal status. The only way out of an open command is an honest `finish`.

ENVELOPE + COMMAND-SPECIFIC EVIDENCE (Task 2 shipped the envelope; Task 6 adds the per-command
matrix). `finish` first validates the COMMON envelope — `schema_version` == 1 and `refs` is an object
— then the per-command, per-status evidence matrix (`validate_closeout`): a think `complete` must carry
a MERGED Think PR + a disposed one-marker gate + an admitted pointer + valid intake coverage; a build
`complete` its per-issue receipts (or an empty ready frontier); an autorun `complete` this session's
`drain: complete`; and so on. Evidence is a set of REFERENCES and observed facts — never a
caller-supplied `passed: true`. Two facts are re-verified against durable state rather than trusted:
intake coverage is re-read from the referenced manifest, and every `no_action` close is checked
against a fresh read-only next-action oracle result. `blocked_external` must cite a deterministic
helper's nonzero exit + a concise diagnostic; it is an honest blocked stop, never a disguised success.
The legal terminal statuses are further narrowed PER COMMAND (a lifecycle/diagnostic command may not
claim a pipeline `waiting_gate`/`no_action`).

CLI:
  idc_command_contract.py start  --repo R --session S --command C --plugin-root P [--args T] [--source T]
  idc_command_contract.py finish --repo R --session S --command C --status STATUS --evidence-json JSON
  idc_command_contract.py status --repo R [--session S] [--json]
Exit codes: 0 = ok; 4 = stale runtime (start only, no record written); 2 = invalid input (unknown
command/status, malformed JSON, invalid evidence envelope, an invalid receipt, or a missing/foreign
active record on finish).
"""
from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)                       # scripts/ — for idc_plugin_freshness
sys.path.insert(0, os.path.join(_HERE, "hooks"))  # scripts/hooks/ — for idc_ledger
import idc_plugin_freshness as freshness  # noqa: E402
import idc_ledger  # noqa: E402

# The eleven governed `/idc:*` entry points. Kept in lockstep with commands/*.md and the
# UserPromptExpansion matcher in hooks/hooks.json.
COMMANDS = {
    "autorun", "build", "doctor", "init", "intake", "janitor",
    "plan", "recirculate", "think", "uninstall", "update",
}
# The four honest ways a command lifecycle can END (the GLOBAL set). Task 6 narrows the legal subset
# PER COMMAND (LEGAL_STATUSES) and attaches command-specific evidence to each.
TERMINAL_STATUSES = {"complete", "waiting_gate", "no_action", "blocked_external"}

# Per-command legal terminal statuses (Task 6 matrix). A pipeline command may wait behind a human gate;
# a planning/build command may honestly report no_action (oracle-backed); a lifecycle/diagnostic
# command either completes or is externally blocked — it may not claim a pipeline handoff it does not
# own. Every command may report `blocked_external` (a proven deterministic-helper failure).
LEGAL_STATUSES = {
    "intake":      {"complete", "blocked_external"},
    "think":       {"complete", "waiting_gate", "blocked_external"},
    "plan":        {"complete", "no_action", "blocked_external"},
    "recirculate": {"complete", "waiting_gate", "blocked_external"},
    "build":       {"complete", "no_action", "blocked_external"},
    "autorun":     {"complete", "waiting_gate", "blocked_external"},
    "janitor":     {"complete", "blocked_external"},
    "init":        {"complete", "blocked_external"},
    "doctor":      {"complete", "blocked_external"},
    "update":      {"complete", "blocked_external"},
    "uninstall":   {"complete", "blocked_external"},
}

# Valid durable dispositions an intake unit may carry after review (idc_intake_manifest). A think
# closeout's remainder units must sit in one of these — never `unclassified`.
_DURABLE_DISPOSITIONS = {"queued", "materialized", "verified_done", "ignored"}


@dataclasses.dataclass(frozen=True)
class CloseoutResult:
    ok: bool
    reason_code: str
    message: str
    normalized_evidence: dict


# ── command-specific evidence helpers ──────────────────────────────────────────────────────────────
def _fail(code: str, message: str) -> CloseoutResult:
    return CloseoutResult(False, code, message, {})


def _ne_str(value: object) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _present(value: object) -> bool:
    """A non-empty reference: a positive int or a non-empty string (an issue number or a locator)."""
    if isinstance(value, bool):
        return False
    if isinstance(value, int):
        return value > 0
    return _ne_str(value)


def _check_blocker(refs: dict) -> CloseoutResult:
    """`blocked_external` proof: a named deterministic helper, its NONZERO exit, and a concise
    diagnostic. This is an honest blocked stop — never a disguised success."""
    blocker = refs.get("blocker")
    if not isinstance(blocker, dict):
        return _fail("blocked-external-no-blocker",
                     "blocked_external requires refs.blocker = {helper, exit, diagnostic}")
    if not _ne_str(blocker.get("helper")):
        return _fail("blocked-external-no-helper", "refs.blocker.helper must name the failing helper")
    code = blocker.get("exit")
    if isinstance(code, bool) or not isinstance(code, int) or code == 0:
        return _fail("blocked-external-zero-exit",
                     "refs.blocker.exit must be the helper's NONZERO exit code (a blocker is not a success)")
    if not _ne_str(blocker.get("diagnostic")):
        return _fail("blocked-external-no-diagnostic", "refs.blocker.diagnostic must be a concise reason")
    return CloseoutResult(True, "ok", "blocked_external cites a deterministic helper failure", {})


def _oracle_action(repo: str):
    """A fresh read-only next-action oracle result for `repo` (Task 5), or None if it could not be
    established (missing repo, invalid/unreadable state, or a throttle) — every such case fails the
    no_action check CLOSED, because an unproven fixpoint is never an honest no_action."""
    if not _ne_str(repo):
        return None
    try:
        import idc_next_action as NEXT  # noqa: E402 — lazy: keep start/status/envelope light
        action = NEXT.decide(repo)
    except Exception:  # noqa: BLE001 — any oracle failure is fail-closed for no_action
        return None
    if action.verdict == "invalid" or action.reason_code == "rate-limited":
        return None
    return action


def _check_no_action(command: str, repo: str) -> CloseoutResult:
    """`no_action` is legal ONLY when a fresh oracle proves this command's lane is empty. Plan needs
    zero admitted considerations; Build needs zero eligible Buildables."""
    action = _oracle_action(repo)
    if action is None:
        return _fail("no-action-unproven",
                     "no_action requires a fresh, valid next-action oracle result for this repo")
    counts = action.counts or {}
    if command == "plan" and counts.get("considerations", 0) != 0:
        return _fail("no-action-contradicted",
                     "no_action rejected — the oracle still reports admitted considerations to plan")
    if command == "build" and counts.get("eligible_buildables", 0) != 0:
        return _fail("no-action-contradicted",
                     "no_action rejected — the oracle still reports eligible Buildable work")
    return CloseoutResult(True, "ok", "no_action is oracle-backed", {})


def _confined_repo_path(repo: str, rel: object) -> str | None:
    """Resolve a repo-relative locator strictly inside `repo` (no absolute path, no `..` escape)."""
    if not _ne_str(repo) or not _ne_str(rel) or os.path.isabs(str(rel)):
        return None
    root = os.path.realpath(os.path.abspath(repo))
    candidate = os.path.realpath(os.path.join(root, str(rel)))
    try:
        if os.path.commonpath((root, candidate)) != root or candidate == root:
            return None
    except ValueError:
        return None
    return candidate


def _check_intake_coverage(repo: str, manifest_rel: object, selected: object) -> CloseoutResult:
    """Re-read the referenced intake manifest from durable state and confirm the WHOLE manifest is
    honestly accounted for: every SELECTED unit is `materialized`, and every OTHER expected unit sits
    in a valid durable disposition. Reading the manifest (not trusting a caller flag) is what blocks a
    closeout that materializes one unit but drops the rest of the exact-once set."""
    path = _confined_repo_path(repo, manifest_rel)
    if path is None or not os.path.isfile(path):
        return _fail("intake-coverage-bad-ref",
                     "refs.intake_manifest must be a repo-relative path to the consumed manifest")
    if not isinstance(selected, list) or not selected or any(not _ne_str(s) for s in selected):
        return _fail("intake-coverage-bad-selected",
                     "refs.intake_selected must be a non-empty list of unit ids")
    try:
        import idc_intake_manifest as INTAKE  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict):
            raise INTAKE.IntakeError("manifest must be a JSON object")
        INTAKE.validate_manifest(manifest)          # exact-once — a dropped unit fails HERE
        INTAKE._resolve_stamped_review(path, manifest)  # requires an independent PASS review
    except Exception as exc:  # noqa: BLE001 — any invalid manifest/review blocks the closeout
        return _fail("intake-coverage-invalid", f"consumed intake manifest is not valid: {exc}")

    expected = set(manifest["expected_unit_ids"])
    selected_set = set(selected)
    if not selected_set <= expected:
        return _fail("intake-coverage-unknown-unit",
                     "refs.intake_selected names units absent from the manifest expected set")
    by_id = {unit["id"]: unit for unit in manifest["units"]}
    for unit_id in expected:
        state = by_id[unit_id]["disposition"]["state"]
        if unit_id in selected_set:
            if state != "materialized":
                return _fail("intake-coverage-unmaterialized",
                             f"selected intake unit {unit_id} is not materialized (state {state!r})")
        elif state not in _DURABLE_DISPOSITIONS:
            return _fail("intake-coverage-remainder",
                         f"unselected expected unit {unit_id} lacks a durable disposition (state {state!r})")
    return CloseoutResult(True, "ok", "intake coverage is complete", {})


def _v_intake(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    # complete: manifest + independent review validate; the intake PR reads MERGED. An intake
    # COMPILATION legitimately leaves every unit queued (nothing materialized yet), so this demands a
    # VALID independently-reviewed manifest, not materialization.
    if not _present(refs.get("manifest")) or not _ne_str(refs.get("review")):
        return _fail("intake-refs", "intake complete needs refs.manifest and refs.review")
    reviewed = _valid_reviewed_manifest(repo, refs.get("manifest"))
    if not reviewed.ok:
        return reviewed
    if not _present(refs.get("intake_pr")) or refs.get("intake_pr_state") != "MERGED":
        return _fail("intake-pr-unmerged", "intake complete requires refs.intake_pr with state MERGED")
    return CloseoutResult(True, "ok", "intake compiled + reviewed + landed", refs)


def _valid_reviewed_manifest(repo: str, manifest_rel: object) -> CloseoutResult:
    path = _confined_repo_path(repo, manifest_rel)
    if path is None or not os.path.isfile(path):
        return _fail("intake-bad-ref", "refs.manifest must be a repo-relative path to the manifest")
    try:
        import idc_intake_manifest as INTAKE  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            manifest = json.load(handle)
        if not isinstance(manifest, dict):
            raise INTAKE.IntakeError("manifest must be a JSON object")
        INTAKE.validate_manifest(manifest)
        INTAKE._resolve_stamped_review(path, manifest)
    except Exception as exc:  # noqa: BLE001
        return _fail("intake-invalid", f"intake manifest is not independently reviewed/valid: {exc}")
    return CloseoutResult(True, "ok", "manifest reviewed + valid", {})


def _v_think(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if refs.get("consideration") != "pass":
        return _fail("think-consideration", "think closeout requires refs.consideration == 'pass'")
    if not _present(refs.get("think_pr")) or not _present(refs.get("gate")) \
            or not _present(refs.get("pointer")):
        return _fail("think-refs", "think closeout needs refs.think_pr, refs.gate, refs.pointer")
    if refs.get("gate_markers") != 1:
        return _fail("think-gate-markers",
                     "think closeout requires exactly one idc-gate-pr marker (refs.gate_markers == 1)")
    if status == "complete":
        if refs.get("think_pr_state") != "MERGED":
            return _fail("think-pr-unmerged", "think complete requires the Think PR MERGED")
        if refs.get("gate_disposition") != "disposed":
            return _fail("think-gate-open", "think complete requires the gate disposed (gate-approved)")
        if refs.get("pointer_state") != "admitted":
            return _fail("think-pointer", "think complete requires the consideration pointer admitted")
        if refs.get("intake_manifest") is not None:
            cov = _check_intake_coverage(repo, refs.get("intake_manifest"), refs.get("intake_selected"))
            if not cov.ok:
                return cov
        return CloseoutResult(True, "ok", "think admitted + intake coverage valid", refs)
    # waiting_gate: same artifacts, PR OPEN, gate + pointer still blocked.
    if refs.get("think_pr_state") != "OPEN":
        return _fail("think-pr-state", "think waiting_gate requires the Think PR OPEN")
    if refs.get("gate_disposition") != "blocked":
        return _fail("think-gate-state", "think waiting_gate requires the gate still blocked")
    if refs.get("pointer_state") != "blocked":
        return _fail("think-pointer-state", "think waiting_gate requires the pointer still blocked")
    return CloseoutResult(True, "ok", "think waiting on the requirements gate", refs)


def _v_plan(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "no_action":
        return _check_no_action("plan", repo)
    for key in ("schema", "matrix", "provenance"):
        if refs.get(key) != "pass":
            return _fail("plan-checks", f"plan complete requires refs.{key} == 'pass'")
    if not _present(refs.get("planning_pr")) or refs.get("planning_pr_state") != "MERGED":
        return _fail("plan-pr-unmerged", "plan complete requires refs.planning_pr MERGED")
    decompositions = refs.get("decompositions")
    if not isinstance(decompositions, dict) or not decompositions \
            or any(not _present(v) for v in decompositions.values()):
        return _fail("plan-decomposition",
                     "plan complete requires refs.decompositions {consideration: child} (non-empty)")
    if not isinstance(refs.get("pointers_retired"), list):
        return _fail("plan-pointers", "plan complete requires refs.pointers_retired (a list)")
    return CloseoutResult(True, "ok", "plan decomposed + admitted", refs)


def _v_recirculate(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "waiting_gate":
        if not _present(refs.get("gate")):
            return _fail("recirc-gate", "recirculate waiting_gate requires a valid requirements gate/Think PR ref")
        return CloseoutResult(True, "ok", "recirculation waiting on the requirements gate", refs)
    # complete: reconciliation ran + every requested ticket/unit has a valid closeout.
    if refs.get("reconciliation") != "ran":
        return _fail("recirc-reconcile", "recirculate complete requires refs.reconciliation == 'ran'")
    closeouts = refs.get("closeouts")
    if not isinstance(closeouts, dict) or any(not _ne_str(v) for v in closeouts.values()):
        return _fail("recirc-closeouts",
                     "recirculate complete requires refs.closeouts {ticket/unit: disposition}")
    return CloseoutResult(True, "ok", "recirculation inbox drained + reconciled", refs)


def _v_build(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "no_action":
        return _check_no_action("build", repo)
    receipts = refs.get("receipts")
    if isinstance(receipts, dict) and receipts and all(_ne_str(v) for v in receipts.values()):
        return CloseoutResult(True, "ok", "build receipts pass", refs)
    if refs.get("frontier") == "none-eligible":
        return CloseoutResult(True, "ok", "no eligible requested item on the ready frontier", refs)
    return _fail("build-receipts",
                 "build complete requires refs.receipts {issue: receipt} or refs.frontier == 'none-eligible'")


def _v_autorun(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "waiting_gate":
        gates = refs.get("gates")
        if not isinstance(gates, list) or not gates:
            return _fail("autorun-gates", "autorun waiting_gate requires a non-empty refs.gates list")
        return CloseoutResult(True, "ok", "autorun paused behind human gate(s)", refs)
    # complete: THIS session's drain reads exactly `drain: complete`.
    if refs.get("drain") != "complete":
        return _fail("autorun-drain", "autorun complete requires refs.drain == 'complete'")
    if refs.get("drain_session") != session:
        return _fail("autorun-drain-session",
                     "autorun complete requires refs.drain_session to be THIS session's drain verdict")
    return CloseoutResult(True, "ok", "autorun drained to fixpoint this session", refs)


def _v_janitor(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    code = refs.get("scanner_exit")
    if isinstance(code, bool) or code not in (0, 1):
        return _fail("janitor-scan", "janitor complete requires refs.scanner_exit of 0 (coherent) or 1 (findings)")
    if code == 1 and refs.get("scanner_clean") is not False:
        return _fail("janitor-hollow-clean",
                     "janitor findings (exit 1) must not claim clean — refs.scanner_clean must be false")
    return CloseoutResult(True, "ok", "janitor scan recorded", refs)


def _v_init(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    for key in ("tracker_config", "scaffold", "hooks"):
        if refs.get(key) != "ok":
            return _fail("init-scaffold", f"init complete requires refs.{key} == 'ok'")
    if refs.get("receipt_version") != 2:
        return _fail("init-receipt", "init complete requires a v2 install receipt (refs.receipt_version == 2)")
    return CloseoutResult(True, "ok", "init scaffolded + stamped a v2 receipt", refs)


def _v_doctor(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    rows = refs.get("rows")
    if not isinstance(rows, list) or not rows:
        return _fail("doctor-rows", "doctor complete requires refs.rows (the captured check rows)")
    if not _ne_str(refs.get("verdict")):
        return _fail("doctor-verdict", "doctor complete requires refs.verdict (a FAIL result is still complete)")
    return CloseoutResult(True, "ok", "doctor captured all rows + a verdict", refs)


def _v_update(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if refs.get("receipt_version") != 2:
        return _fail("update-receipt", "update complete requires a verified v2 receipt (refs.receipt_version == 2)")
    running = refs.get("running_version")
    receipt = refs.get("receipt_plugin_version")
    if not _ne_str(running) or running != receipt:
        return _fail("update-version-mismatch",
                     "update complete requires running_version == receipt_plugin_version")
    return CloseoutResult(True, "ok", "update resynced + the receipt matches the running version", refs)


def _v_uninstall(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    outcome = refs.get("outcome")
    if outcome not in ("applied", "no-action"):
        return _fail("uninstall-outcome", "uninstall complete requires refs.outcome of 'applied' or 'no-action'")
    if outcome == "applied" and not _ne_str(refs.get("archive")):
        return _fail("uninstall-archive", "an applied uninstall requires refs.archive (the work-product archive path)")
    return CloseoutResult(True, "ok", "uninstall manifest applied or a no-action result", refs)


_COMMAND_VALIDATORS = {
    "intake": _v_intake, "think": _v_think, "plan": _v_plan, "recirculate": _v_recirculate,
    "build": _v_build, "autorun": _v_autorun, "janitor": _v_janitor, "init": _v_init,
    "doctor": _v_doctor, "update": _v_update, "uninstall": _v_uninstall,
}


def args_digest(text: str) -> str:
    """The lowercase-hex SHA-256 of the command's raw argument text — a stable, non-reversible
    fingerprint recorded on the lifecycle record (so a closeout can be tied to the exact invocation
    without persisting the possibly-sensitive argument text itself)."""
    return hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def validate_closeout(command: str, status: str, evidence: object,
                      repo: str | None = None, session: str | None = None) -> CloseoutResult:
    """Validate a closeout's command, terminal status, COMMON envelope, and per-command evidence
    (Task 6). Returns a CloseoutResult; ok=False carries a machine reason_code + a human message.

    Order: (1) known command; (2) globally-known status; (3) common envelope (schema_version == 1 and
    refs an object); (4) the status is LEGAL for this command; (5) the command-specific evidence matrix
    (`blocked_external` uniformly; `no_action` against a fresh oracle; `complete`/`waiting_gate` against
    each command's required references — intake coverage re-read from the durable manifest). `repo` and
    `session` feed the two facts that are re-verified rather than trusted (oracle + coverage; the
    autorun `drain_session` binding)."""
    if command not in COMMANDS:
        return CloseoutResult(False, "unknown-command", f"unknown command {command!r}", {})
    if status not in TERMINAL_STATUSES:
        return CloseoutResult(
            False, "unknown-status",
            f"unknown terminal status {status!r} (expected one of {sorted(TERMINAL_STATUSES)})", {})
    if not isinstance(evidence, dict):
        return CloseoutResult(False, "evidence-not-object", "evidence must be a JSON object", {})
    schema_version = evidence.get("schema_version")
    # STRICT: the INTEGER 1 only. Python's `True == 1` and `1.0 == 1`, so a bare `!= 1` would admit
    # JSON `true` (bool) and `1.0` (float). Reject bool explicitly (bool is a subclass of int) and
    # any non-int type, so only a genuine integer 1 passes.
    if isinstance(schema_version, bool) or not isinstance(schema_version, int) or schema_version != 1:
        return CloseoutResult(
            False, "bad-schema-version",
            f"evidence.schema_version must be the integer 1, got {schema_version!r}", {})
    refs = evidence.get("refs")
    if not isinstance(refs, dict):
        return CloseoutResult(False, "refs-not-object", "evidence.refs must be an object", {})

    # (4) the status must be LEGAL for this specific command (Task 6 matrix) — a lifecycle/diagnostic
    # command cannot claim a pipeline waiting_gate/no_action it does not own.
    if status not in LEGAL_STATUSES[command]:
        return CloseoutResult(
            False, "status-not-legal-for-command",
            f"{status!r} is not a legal terminal status for /idc:{command} "
            f"(legal: {sorted(LEGAL_STATUSES[command])})", {})

    # (5) command-specific evidence. blocked_external is uniform across every command.
    if status == "blocked_external":
        result = _check_blocker(refs)
    else:
        result = _COMMAND_VALIDATORS[command](status, refs, repo or "", session or "")
    if not result.ok:
        return result
    return CloseoutResult(True, "ok", "closeout valid", evidence)


def register_start(cwd: str, session_id: str, command: str, plugin_version: str,
                   args_text: str, source: str) -> dict:
    """Open (idempotently upsert) the command's active lifecycle record — the entry gate's helper.
    Computes the argument digest and delegates the single ledger write. Assumes freshness/admission
    was already decided by the caller (the entry gate). Returns the record dict when the write
    PERSISTED, `{}` outside a governed repo, or None when the ledger write FAILED (Fix 2)."""
    return idc_ledger.command_start(
        cwd, session_id, command, plugin_version, args_digest(args_text or ""), source or "")


def active_records(cwd: str, session_id: str) -> list:
    """The active command records for `session_id` — the SAME read path `status` reports from
    (idc_ledger.active_commands). Exposed so the entry gate can READ BACK after a start and CONFIRM
    the record actually persisted, rather than trusting the writer's return (Fix 2)."""
    return idc_ledger.active_commands(cwd, session_id)


# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
def _cmd_start(args) -> int:
    if args.command not in COMMANDS:
        print(f"idc-command-contract: unknown command {args.command!r}", file=sys.stderr)
        return 2
    try:
        result = freshness.evaluate(args.plugin_root, repo=args.repo)
    except freshness.InvalidReceiptError as exc:
        print(f"idc-command-contract: invalid receipt: {exc}", file=sys.stderr)
        return 2
    # A stale runtime must never OPEN an obligation: a stale command body would record work it cannot
    # honestly discharge. Exit 4 without writing a record (the admission gate has already refused the
    # expansion; this is the second, write-side guard for any non-hook caller).
    if result.verdict == "stale":
        print("idc-command-contract: refusing to open a command record on a stale plugin runtime "
              f"(running {result.running_version}, required {result.required_version}); "
              "run /reload-plugins, then retry.", file=sys.stderr)
        return 4
    rec = register_start(args.repo, args.session, args.command, result.running_version or "",
                         args.args or "", args.source or "")
    if rec is None:
        # A governed repo where the ledger write did NOT persist. Never report success for an
        # obligation that was not recorded (Fix 2) — the Stop gate could not enforce its closeout.
        print("idc-command-contract: could not persist the command record (the session state "
              "ledger write failed — check that the repo root is writable), so no obligation was "
              "opened.", file=sys.stderr)
        return 1
    return 0


def _cmd_finish(args) -> int:
    try:
        evidence = json.loads(args.evidence_json)
    except ValueError as exc:
        print(f"idc-command-contract: malformed --evidence-json: {exc}", file=sys.stderr)
        return 2
    verdict = validate_closeout(args.command, args.status, evidence, repo=args.repo, session=args.session)
    if not verdict.ok:
        print(f"idc-command-contract: rejected closeout [{verdict.reason_code}]: {verdict.message}",
              file=sys.stderr)
        return 2
    rec = idc_ledger.command_finish(
        args.repo, args.session, args.command, args.status, verdict.normalized_evidence)
    if rec is None:
        print(f"idc-command-contract: no active {args.command!r} command record owned by session "
              f"{args.session!r} to finish (a foreign session cannot finish another's record)",
              file=sys.stderr)
        return 2
    return 0


def _cmd_status(args) -> int:
    active = idc_ledger.active_commands(args.repo, args.session)
    finished = [c for c in idc_ledger.read_state(args.repo)["commands"]
                if c.get("state") != "active"]
    if args.session:
        finished = [c for c in finished if c.get("session_id") == args.session]
    if args.json:
        print(json.dumps({"active": active, "finished": finished}, indent=2, sort_keys=True))
    else:
        for c in active:
            print(f"active  {c.get('session_id')}  {c.get('command')}")
        for c in finished:
            closeout = c.get("closeout") or {}
            print(f"done    {c.get('session_id')}  {c.get('command')}  {closeout.get('status')}")
    return 0


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="IDC command lifecycle contract (runtime-neutral)")
    sub = ap.add_subparsers(dest="op", required=True)

    sp = sub.add_parser("start", help="open (upsert) a command's active lifecycle record")
    sp.add_argument("--repo", required=True)
    sp.add_argument("--session", required=True)
    sp.add_argument("--command", required=True)
    sp.add_argument("--plugin-root", required=True)
    sp.add_argument("--args", default="")
    sp.add_argument("--source", default="")

    fp = sub.add_parser("finish", help="close an active command with a validated terminal status")
    fp.add_argument("--repo", required=True)
    fp.add_argument("--session", required=True)
    fp.add_argument("--command", required=True)
    fp.add_argument("--status", required=True)
    fp.add_argument("--evidence-json", required=True)

    tp = sub.add_parser("status", help="show the session's active + finished command records")
    tp.add_argument("--repo", required=True)
    tp.add_argument("--session", default=None)
    tp.add_argument("--json", action="store_true")

    args = ap.parse_args(argv)
    if args.op == "start":
        return _cmd_start(args)
    if args.op == "finish":
        return _cmd_finish(args)
    if args.op == "status":
        return _cmd_status(args)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
