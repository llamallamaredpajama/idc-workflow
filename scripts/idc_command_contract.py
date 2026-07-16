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
`complete` its per-issue STRUCTURED merged-PR receipts (or an oracle-backed empty ready frontier); an
autorun `complete` this session's PERSISTED `drain: complete` verdict; and so on. Evidence is a set of
REFERENCES to DURABLE artifacts the validator re-verifies for real — never a caller-supplied `passed:
true` or a `"pass"` string. Facts re-read from durable state rather than trusted: intake coverage is
re-read from the recorded manifest (finding 2); every `no_action`/empty-frontier close is checked
against a fresh read-only next-action oracle; the autorun `drain: complete` is read from
`.idc-drain-verdict.json` (session-scoped); the plan matrix is re-validated through `idc_matrix_check`;
and a `blocked_external` helper must be a REAL shipped deterministic script. `blocked_external` must
cite that helper's nonzero exit + a concise diagnostic; it is an honest blocked stop, never a disguised
success.
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
import re
import subprocess
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


def _known_helper(name: object) -> bool:
    """True iff `name` is a REAL deterministic helper shipped with the plugin — a basename that exists
    under `scripts/` or `scripts/hooks/`. A blocker must cite a helper that EXISTS (verify the
    referenced artifact for real), so a phantom helper name can never manufacture a blocked stop."""
    if not _ne_str(name):
        return False
    base = os.path.basename(str(name))
    if base != str(name) or not (base.endswith(".py") or base.endswith(".sh")):
        return False
    return os.path.isfile(os.path.join(_HERE, base)) or os.path.isfile(os.path.join(_HERE, "hooks", base))


# The autorun drain writes a NON-complete verdict (rate-limited/unknown/board-read-error/…) to the
# durable, session-scoped `.idc-drain-verdict.json` on EVERY blocked path — so a blocked_external that
# cites the drain can be RE-DERIVED from that artifact rather than a caller-typed exit/diagnostic.
_DRAIN_HELPER = "idc_autorun_drain.py"


def _check_blocker(refs: dict, repo: str, session: str) -> CloseoutResult:
    """`blocked_external` proof: a REAL shipped deterministic helper, its NONZERO exit, and a concise
    diagnostic. This is an honest blocked stop — never a disguised success. For the DRAIN helper the
    blocked verdict is additionally RE-DERIVED from THIS session's persisted drain verdict (round-2
    F1) — the durable artifact the drain wrote — so an invented drain failure is refused."""
    blocker = refs.get("blocker")
    if not isinstance(blocker, dict):
        return _fail("blocked-external-no-blocker",
                     "blocked_external requires refs.blocker = {helper, exit, diagnostic}")
    if not _ne_str(blocker.get("helper")):
        return _fail("blocked-external-no-helper", "refs.blocker.helper must name the failing helper")
    if not _known_helper(blocker.get("helper")):
        return _fail("blocked-external-unknown-helper",
                     "refs.blocker.helper must name a real deterministic helper shipped under scripts/ "
                     "(a phantom helper cannot manufacture a blocked stop)")
    code = blocker.get("exit")
    if isinstance(code, bool) or not isinstance(code, int) or code == 0:
        return _fail("blocked-external-zero-exit",
                     "refs.blocker.exit must be the helper's NONZERO exit code (a blocker is not a success)")
    if not _ne_str(blocker.get("diagnostic")):
        return _fail("blocked-external-no-diagnostic", "refs.blocker.diagnostic must be a concise reason")
    if os.path.basename(str(blocker.get("helper"))) == _DRAIN_HELPER:
        # RE-DERIVE the drain blocker from the DURABLE artifact the drain wrote (session-scoped,
        # staleness-guarded) — never the caller's typed exit/diagnostic. The drain persists a
        # non-complete verdict + nonzero exit on every blocked path, so an invented drain failure
        # (no such verdict for THIS session) can no longer manufacture a blocked stop.
        verdict = _persisted_drain_verdict(repo, session)
        if verdict is None:
            return _fail("blocked-external-drain-unproven",
                         "blocked_external citing the drain requires THIS session's persisted drain "
                         "verdict (.idc-drain-verdict.json) — none found (absent, foreign, or stale)")
        token = verdict.get("verdict")
        vexit = verdict.get("exit")
        if token == "complete" or isinstance(vexit, bool) or vexit in (0, None):
            return _fail("blocked-external-drain-not-blocked",
                         "blocked_external citing the drain requires a NON-complete persisted verdict "
                         f"with a nonzero exit; got verdict={token!r} exit={vexit!r}")
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


# ── real GitHub-state reads (round-2 F1/F2): a PR merged-state / issue body is a claim that lives on
# GitHub, so the validator READS it for real (`gh pr view` / `gh issue view`) and never trusts a
# caller `state:"MERGED"`. Every read is fail-closed: gh missing, a nonzero exit, or unparseable JSON
# all yield None, and the caller treats None as "not proven". Hermetic tests inject a fake `gh` on PATH
# (the suite's established pattern), including a sabotage where the fake returns UNMERGED. ─────────────
_GH_TIMEOUT_S = 30


def _gh_capture(repo: str, args: list) -> str | None:
    """Run `gh <args>` in `repo`, returning stdout on a zero exit, else None (gh absent, nonzero, or
    a timeout). Read-only by contract — callers pass only `view`/read subcommands."""
    if not _ne_str(repo) or not os.path.isdir(repo):
        return None
    try:
        proc = subprocess.run(["gh", *args], cwd=repo, capture_output=True, text=True,
                              timeout=_GH_TIMEOUT_S)
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def _gh_pr_merged(repo: str, pr: object):
    """A REAL `gh pr view` read of `pr`'s merged-state. Returns True (MERGED), False (a real read
    proved NOT merged), or None (could not establish — fail closed). The caller NEVER supplies the
    state; it is re-derived here."""
    if isinstance(pr, bool) or not _present(pr):
        return None
    try:
        pr_int = int(pr)
    except (TypeError, ValueError):
        return None
    out = _gh_capture(repo, ["pr", "view", str(pr_int), "--json", "state,mergedAt"])
    if out is None:
        return None
    try:
        info = json.loads(out)
    except ValueError:
        return None
    if not isinstance(info, dict):
        return None
    return info.get("state") == "MERGED" or bool(info.get("mergedAt"))


def _gh_issue_body(repo: str, num: object):
    """The LIVE github issue body for `num` via `gh issue view`, or None (missing/unreadable — fail
    closed). A successful read also PROVES the issue exists."""
    if isinstance(num, bool) or not _present(num):
        return None
    try:
        num_int = int(num)
    except (TypeError, ValueError):
        return None
    return _gh_capture(repo, ["issue", "view", str(num_int), "--json", "body", "-q", ".body"])


def _repo_backend(repo: str) -> str:
    """The repo's tracker backend (`github`/`filesystem`), tolerant: any read problem defaults to
    `filesystem` (the historical default) so a github-only re-verification is only DEMANDED where the
    config actually says github."""
    try:
        import idc_next_action as NEXT  # noqa: E402 — reuse the one constrained config reader
        backend, _ = NEXT._read_tracker_config(repo)
        return backend
    except Exception:  # noqa: BLE001
        return "filesystem"


def _load_issue_numbers(repo: str):
    """The set of live tracker issue numbers (as canonical strings) via the shared reader, or None on
    any read failure (fail closed). Used to verify decomposition children EXIST on the board."""
    try:
        import idc_next_action as NEXT  # noqa: E402
        return {_gate_key(i["number"]) for i in NEXT._load_tracker_issues(repo)}
    except Exception:  # noqa: BLE001
        return None


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


def _think_record_intake(repo: str, session: str):
    """The intake manifest + selected units recorded on THIS session's ACTIVE think record at start
    (finding 2), or (None, None). This is the DURABLE source of intake mode: a finish that omits the
    intake fields can no longer make an intake-mode run look non-intake and slip a dropped-unit close
    past coverage. Read tolerantly — any read failure yields (None, None) and the finish falls back to
    the caller-supplied ref (belt-and-suspenders for a runtime with no record readback)."""
    if not _ne_str(repo) or not _ne_str(session):
        return None, None
    try:
        for rec in idc_ledger.active_commands(repo, session):
            if rec.get("command") == "think" and rec.get("intake_manifest"):
                return rec.get("intake_manifest"), rec.get("intake_units") or []
    except Exception:  # noqa: BLE001 — a ledger read failure must not brick the closeout
        return None, None
    return None, None


def _v_think(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if refs.get("consideration") != "pass":
        return _fail("think-consideration", "think closeout requires refs.consideration == 'pass'")
    if not _present(refs.get("think_pr")) or not _present(refs.get("gate")) \
            or not _present(refs.get("pointer")):
        return _fail("think-refs", "think closeout needs refs.think_pr, refs.gate, refs.pointer")
    if refs.get("gate_markers") != 1:
        return _fail("think-gate-markers",
                     "think closeout requires exactly one idc-gate-pr marker (refs.gate_markers == 1)")
    # Intake coverage is enforced from the DURABLE record on EVERY closeout path (finding 2). If the
    # active record says this run is intake-mode (started with --doc/--unit), coverage is MANDATORY and
    # re-read from the RECORDED manifest + selected units — a finish that omits the intake fields cannot
    # bypass it, and it applies to waiting_gate as well as complete. Only when no record marker exists
    # do we fall back to a caller-supplied intake ref (still verified, never trusted).
    rec_manifest, rec_units = _think_record_intake(repo, session)
    if rec_manifest is not None:
        cov = _check_intake_coverage(repo, rec_manifest, rec_units)
        if not cov.ok:
            return cov
    elif refs.get("intake_manifest") is not None:
        cov = _check_intake_coverage(repo, refs.get("intake_manifest"), refs.get("intake_selected"))
        if not cov.ok:
            return cov
    if status == "complete":
        # The Think PR merged-state is a GitHub claim — RE-READ it (never a caller state:"MERGED"),
        # the same _gh_pr_merged path plan/build use. The caller passes only the PR NUMBER
        # (refs.think_pr, already required above); the validator re-derives merged-state for real and
        # fails closed when it cannot be established (gh absent/errored or the PR reads NOT merged).
        merged = _gh_pr_merged(repo, refs.get("think_pr"))
        if merged is None:
            return _fail("think-pr-unverified",
                         "think complete: the Think PR merged-state could not be verified by a real gh "
                         "read (a caller state is never trusted) — fail closed")
        if not merged:
            return _fail("think-pr-unmerged", "think complete requires the Think PR MERGED (real gh read)")
        if refs.get("gate_disposition") != "disposed":
            return _fail("think-gate-open", "think complete requires the gate disposed (gate-approved)")
        if refs.get("pointer_state") != "admitted":
            return _fail("think-pointer", "think complete requires the consideration pointer admitted")
        return CloseoutResult(True, "ok", "think admitted + intake coverage valid", refs)
    # waiting_gate: same artifacts, PR OPEN, gate + pointer still blocked.
    if refs.get("think_pr_state") != "OPEN":
        return _fail("think-pr-state", "think waiting_gate requires the Think PR OPEN")
    if refs.get("gate_disposition") != "blocked":
        return _fail("think-gate-state", "think waiting_gate requires the gate still blocked")
    if refs.get("pointer_state") != "blocked":
        return _fail("think-pointer-state", "think waiting_gate requires the pointer still blocked")
    return CloseoutResult(True, "ok", "think waiting on the requirements gate", refs)


def _valid_matrix(repo: str, matrix_rel: object) -> CloseoutResult:
    """Re-validate the referenced deconfliction matrix — a DURABLE repo artifact Plan wrote — through
    idc_matrix_check, rather than trusting a caller `matrix: "pass"` string. A missing file or a matrix
    that fails deconfliction (e.g. same-wave pillars sharing a surface) fails the closeout closed."""
    path = _confined_repo_path(repo, matrix_rel)
    if path is None or not os.path.isfile(path):
        return _fail("plan-matrix-bad-ref",
                     "refs.matrix must be a repo-relative path to the deconfliction matrix Plan wrote")
    try:
        import idc_matrix_check as MX  # noqa: E402 — lazy
        with open(path, encoding="utf-8") as handle:
            problems = MX.check(handle.read())
    except Exception as exc:  # noqa: BLE001 — an unreadable/unparseable matrix blocks the closeout
        return _fail("plan-matrix-invalid", f"the referenced matrix could not be validated: {exc}")
    if problems:
        return _fail("plan-matrix-fail", f"the referenced matrix fails deconfliction: {problems[0]}")
    return CloseoutResult(True, "ok", "matrix re-validated", {})


def _verify_decomposition(repo: str, matrix_rel: object, children: list) -> CloseoutResult:
    """Re-verify Plan's decomposition CHILDREN from durable state (round-2 F2). On the github backend
    the children are live issues: RE-RUN the shipped schema check on each child's live body AND
    re-derive its `idc-provenance` marker against the matrix Plan authored (both are github-only by
    the shipped helpers' own design) — a missing child, a schema-invalid body, or an absent/mismatched
    provenance marker fails closed. On the filesystem backend (no issue bodies) the children are
    verified to EXIST via the shared tracker reader. Either way a caller can no longer assert
    'children exist / schema+provenance pass' — the validator re-derives it."""
    backend = _repo_backend(repo)
    if backend == "github":
        matrix_path = _confined_repo_path(repo, matrix_rel)
        if matrix_path is None or not os.path.isfile(matrix_path):
            return _fail("plan-matrix-bad-ref", "plan complete requires a repo-relative matrix path")
        try:
            import idc_matrix_check as MX  # noqa: E402
            import idc_schema_check as SCHEMA  # noqa: E402
            import idc_recirc_sweep as SWEEP  # noqa: E402
            with open(matrix_path, encoding="utf-8") as handle:
                pillar_ids = {p["id"] for p in MX.parse_matrix(handle.read()) if p.get("id")}
        except Exception as exc:  # noqa: BLE001
            return _fail("plan-matrix-invalid", f"could not load the matrix pillar ids: {exc}")
        matrix_name = os.path.basename(str(matrix_rel))
        for child in children:
            body = _gh_issue_body(repo, child)
            if body is None:
                return _fail("plan-child-missing",
                             f"decomposition child #{child} could not be read from the board (fail closed)")
            problems = SCHEMA.check(body)
            if problems:
                return _fail("plan-child-schema",
                             f"decomposition child #{child} fails the issue-body schema check: {problems[0]}")
            prov = SWEEP.provenance_of(body)
            if not prov or prov.get("matrix") != matrix_name or prov.get("pillar") not in pillar_ids:
                return _fail("plan-child-provenance",
                             f"decomposition child #{child} lacks a valid idc-provenance marker for "
                             f"the authored matrix (re-run provenance check)")
        return CloseoutResult(True, "ok", "decomposition children re-verified (schema + provenance)", {})
    # filesystem: no issue bodies to schema/provenance-check — verify the children EXIST on the board.
    numbers = _load_issue_numbers(repo)
    if numbers is None:
        return _fail("plan-children-unreadable",
                     "plan complete could not read the tracker to verify decomposition children (fail closed)")
    missing = sorted(_gate_key(c) for c in children if _gate_key(c) not in numbers)
    if missing:
        return _fail("plan-child-missing",
                     f"decomposition children not present in the tracker: {', '.join('#' + m for m in missing)}")
    return CloseoutResult(True, "ok", "decomposition children exist on the tracker", {})


def _v_plan(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "no_action":
        return _check_no_action("plan", repo)
    # The deconfliction matrix is a DURABLE artifact — re-validate the referenced file (never a caller
    # "pass").
    mcheck = _valid_matrix(repo, refs.get("matrix"))
    if not mcheck.ok:
        return mcheck
    # The planning PR merged-state is a GitHub claim — RE-READ it (never a caller state:"MERGED").
    merged = _gh_pr_merged(repo, refs.get("planning_pr"))
    if merged is None:
        return _fail("plan-pr-unverified",
                     "plan complete: the planning PR merged-state could not be verified by a real gh "
                     "read (a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("plan-pr-unmerged", "plan complete requires the planning PR MERGED (real gh read)")
    decompositions = refs.get("decompositions")
    if not isinstance(decompositions, dict) or not decompositions \
            or any(not _present(v) for v in decompositions.values()):
        return _fail("plan-decomposition",
                     "plan complete requires refs.decompositions {consideration: child} (non-empty)")
    # pointers_retired must be CROSS-CHECKED against the re-derived delta: every consideration that was
    # decomposed must have its pointer retired, so `pointers_retired:[]` is valid ONLY when nothing was
    # decomposed (round-2 F2) — an empty list against real decompositions is refused.
    pointers = refs.get("pointers_retired")
    if not isinstance(pointers, list):
        return _fail("plan-pointers", "plan complete requires refs.pointers_retired (a list)")
    retired = {_gate_key(p) for p in pointers}
    decomposed = {_gate_key(k) for k in decompositions}
    if decomposed - retired:
        missing = sorted(decomposed - retired)
        return _fail("plan-pointers-open",
                     "plan complete requires every decomposed consideration's pointer retired; "
                     f"still-open: {', '.join('#' + m for m in missing)}")
    # Re-verify the decomposition children (existence + schema + provenance) from durable state.
    dcheck = _verify_decomposition(repo, refs.get("matrix"), list(decompositions.values()))
    if not dcheck.ok:
        return dcheck
    return CloseoutResult(True, "ok", "plan decomposed + admitted (matrix + PR + children re-verified)", refs)


def _reconciliation_verdict(repo: str, session: str):
    """RE-DERIVE the recirculation reconciliation verdict from durable state by RE-RUNNING the
    deterministic reconciliation READ-ONLY (round-2 F5-r2) — never a caller `reconciliation:"ran"`
    string. Forces `IDC_HOOKS_OBSERVE_ONLY=1` so the re-run is a pure dry run (no board comment, no
    ledger taint) that still reads the inbox/board and returns the same verdict the drain would. A
    nonexistent/ungoverned/unreadable repo yields `ungoverned`/`unknown` → None (fail-closed). Returns
    the verdict string only when it is a settled `reconciled`/`complete`, else None."""
    if not _ne_str(repo):
        return None
    prev = os.environ.get("IDC_HOOKS_OBSERVE_ONLY")
    try:
        import idc_recirc_reconcile as RC  # noqa: E402 — lazy
        import idc_recirc_closeout_gate as RG  # noqa: E402 — for its backend reader
        os.environ["IDC_HOOKS_OBSERVE_ONLY"] = "1"   # force a side-effect-free re-run
        backend = RG._read_backend(repo) or "filesystem"
        verdict = RC.reconcile(repo, backend, session or None)[0]
    except Exception:  # noqa: BLE001 — any reconciliation failure fails the closeout closed
        return None
    finally:
        if prev is None:
            os.environ.pop("IDC_HOOKS_OBSERVE_ONLY", None)
        else:
            os.environ["IDC_HOOKS_OBSERVE_ONLY"] = prev
    return verdict if verdict in ("reconciled", "complete") else None


def _v_recirculate(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "waiting_gate":
        if not _present(refs.get("gate")):
            return _fail("recirc-gate", "recirculate waiting_gate requires a valid requirements gate/Think PR ref")
        return CloseoutResult(True, "ok", "recirculation waiting on the requirements gate", refs)
    # complete: reconciliation is RE-DERIVED from durable state (a read-only re-run of the
    # deterministic reconciliation — never a caller `reconciliation:"ran"` string), and every
    # requested ticket/unit carries a valid closeout. A nonexistent/unreadable repo fails closed.
    if _reconciliation_verdict(repo, session) is None:
        return _fail("recirc-reconcile",
                     "recirculate complete requires the reconciliation to RE-DERIVE as "
                     "reconciled/complete from durable state (a read-only re-run) — a caller "
                     "'reconciliation:\"ran\"' is not proof, and a nonexistent/unreadable repo fails closed")
    closeouts = refs.get("closeouts")
    if not isinstance(closeouts, dict) or any(not _ne_str(v) for v in closeouts.values()):
        return _fail("recirc-closeouts",
                     "recirculate complete requires refs.closeouts {ticket/unit: disposition}")
    return CloseoutResult(True, "ok", "recirculation inbox drained + reconciled (re-derived)", refs)


def _valid_build_receipt(issue: object, receipt: object, repo: str) -> CloseoutResult:
    """A build receipt references a merged PR by NUMBER — `{pr: <n>}` — and the validator RE-READS the
    PR's merged-state for real (`gh pr view`), never trusting a caller `state:"MERGED"` (round-2 F1).
    The issue key must be a real reference and the PR a real number; a merged-state that cannot be
    proven by a real read (gh absent/errored, or the PR reads NOT merged) fails the receipt closed."""
    if not _present(issue):
        return _fail("build-receipt-issue", "each build receipt must be keyed by a real issue reference")
    if not isinstance(receipt, dict):
        return _fail("build-receipt-shape",
                     f"build receipt for {issue} must be {{pr}} referencing a MERGED PR "
                     f"(an arbitrary receipt string is not proof)")
    pr = receipt.get("pr")
    if not _present(pr):
        return _fail("build-receipt-pr", f"build receipt for {issue} must cite a real PR (refs.receipts.{issue}.pr)")
    merged = _gh_pr_merged(repo, pr)
    if merged is None:
        return _fail("build-receipt-unverified",
                     f"build receipt for {issue}: PR #{pr}'s merged-state could not be verified by a "
                     f"real gh read (a caller state is never trusted) — fail closed")
    if not merged:
        return _fail("build-receipt-unmerged",
                     f"build receipt for {issue}: the real gh read shows PR #{pr} is NOT merged")
    return CloseoutResult(True, "ok", "receipt ok", {})


def _v_build(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "no_action":
        return _check_no_action("build", repo)
    receipts = refs.get("receipts")
    if isinstance(receipts, dict) and receipts:
        for issue, receipt in receipts.items():
            result = _valid_build_receipt(issue, receipt, repo)
            if not result.ok:
                return result
        return CloseoutResult(True, "ok", "build receipts reference merged PRs (re-read)", refs)
    if refs.get("frontier") == "none-eligible":
        # an empty ready frontier is oracle-backed, never trusted (the same door as no_action).
        return _check_no_action("build", repo)
    return _fail("build-receipts",
                 "build complete requires refs.receipts {issue: {pr, state:'MERGED'}} "
                 "or refs.frontier == 'none-eligible' (oracle-backed)")


def _persisted_drain_verdict(repo: str, session: str):
    """THIS session's PERSISTED drain verdict (`.idc-drain-verdict.json`, Stage E2) via
    idc_drain_verdict.current_verdict — a DURABLE artifact the drain wrote, session-scoped and
    staleness-guarded by that reader. None when there is no fresh verdict for THIS session (absent,
    foreign, or stale). Read tolerantly: any failure yields None → the autorun complete fails closed."""
    if not _ne_str(repo) or not _ne_str(session):
        return None
    try:
        import idc_drain_verdict as DV  # noqa: E402 — lazy (scripts/hooks is already on sys.path)
        return DV.current_verdict(repo, session)
    except Exception:  # noqa: BLE001 — a verdict read failure is fail-closed for autorun complete
        return None


def _gate_key(ref: object) -> str:
    """Canonicalize a gate reference for comparison: an int, `708`, or `#708` all key on `708`."""
    return str(ref).lstrip("#").strip()


def _v_autorun(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    if status == "waiting_gate":
        gates = refs.get("gates")
        if not isinstance(gates, list) or not gates or any(not _present(g) for g in gates):
            return _fail("autorun-gates", "autorun waiting_gate requires a non-empty refs.gates list")
        # CONSULT THE ORACLE (round-2 F5-r2): a nonempty caller list is not proof. The oracle must
        # report a human-gate wait as the live blocking state (no actionable pipeline work ahead of
        # it), and every NAMED gate must be one of the oracle's live gates. A nonexistent/unreadable
        # repo cannot establish the oracle → fail closed.
        action = _oracle_action(repo)
        if action is None:
            return _fail("autorun-gate-unproven",
                         "autorun waiting_gate requires a fresh, valid next-action oracle result for this repo")
        if action.reason_code != "waiting-human-gate":
            return _fail("autorun-gate-contradicted",
                         f"autorun waiting_gate rejected — the oracle reports {action.reason_code!r}, "
                         "not a human-gate wait (there is still actionable pipeline work or a fixpoint)")
        oracle_gates = {_gate_key(r) for r in (action.refs or ())}
        if not {_gate_key(g) for g in gates} <= oracle_gates:
            return _fail("autorun-gate-mismatch",
                         "autorun waiting_gate names gate(s) that are not among the oracle's live "
                         "blocking gates")
        return CloseoutResult(True, "ok", "autorun paused behind the oracle's live human gate(s)", refs)
    # complete: THIS session's PERSISTED drain verdict must read exactly `complete`. The drain status
    # is read from the DURABLE artifact (.idc-drain-verdict.json), never a caller-supplied drain string
    # — a forged `refs.drain` can no longer clear the obligation.
    verdict = _persisted_drain_verdict(repo, session)
    if verdict is None:
        return _fail("autorun-drain",
                     "autorun complete requires THIS session's persisted drain verdict "
                     "(.idc-drain-verdict.json) — none found (absent, foreign, or stale)")
    if verdict.get("verdict") != "complete":
        return _fail("autorun-drain-incomplete",
                     f"autorun complete requires the persisted drain verdict to be 'complete', "
                     f"got {verdict.get('verdict')!r}")
    return CloseoutResult(True, "ok", "autorun drained to fixpoint this session (persisted verdict)", refs)


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


_IDC_PLUGIN_NAME = "idc@idc-workflow"
_GOVERNANCE_ANCHOR = "docs/workflow/tracker-config.yaml"


def _plugin_still_enabled(settings_path: str) -> bool:
    """True iff the IDC plugin is STILL enabled in the settings file (round-2 F4-r2 'settings
    mutated' check). Fail-closed: an unreadable/unparseable settings file reads as still-enabled, so
    an applied uninstall cannot claim the key was stripped without a readable, stripped file."""
    try:
        with open(settings_path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, UnicodeError, ValueError):
        return True
    plugins = data.get("enabledPlugins") if isinstance(data, dict) else None
    if isinstance(plugins, dict):
        return _IDC_PLUGIN_NAME in plugins
    if isinstance(plugins, list):
        return _IDC_PLUGIN_NAME in plugins
    return False


def _v_uninstall(status: str, refs: dict, repo: str, session: str) -> CloseoutResult:
    outcome = refs.get("outcome")
    if outcome not in ("applied", "no-action"):
        return _fail("uninstall-outcome", "uninstall complete requires refs.outcome of 'applied' or 'no-action'")
    if outcome == "no-action":
        return CloseoutResult(True, "ok", "uninstall no-action (nothing to remove)", refs)
    # applied: the destructive work must have ACTUALLY HAPPENED — validate it by INDEPENDENT checks,
    # never a caller assertion (round-2 F4-r2). This is what stops a finish from recording 'applied'
    # before the uninstall ran.
    removed = refs.get("removed")
    if not isinstance(removed, list) or not removed or any(not _ne_str(p) for p in removed):
        return _fail("uninstall-removed",
                     "an applied uninstall requires refs.removed — a non-empty list of the footprint "
                     "paths that must now be ABSENT")
    for rel in removed:
        path = _confined_repo_path(repo, rel)
        if path is None:
            return _fail("uninstall-removed-bad-ref", f"refs.removed path {rel!r} must be repo-relative")
        if os.path.exists(path):
            return _fail("uninstall-not-removed",
                         f"refs.removed names {rel!r} but it is STILL PRESENT — the uninstall work did "
                         f"not complete (a closeout cannot record 'applied' before doing the removal)")
    # The governance anchor + ledger substrate must STILL be present at finish: their removal is the
    # single documented POST-finish step, so a finish that runs after the anchor is gone is refused.
    anchor = _confined_repo_path(repo, _GOVERNANCE_ANCHOR)
    if anchor is None or not os.path.exists(anchor):
        return _fail("uninstall-anchor-gone",
                     "the governance anchor (docs/workflow/tracker-config.yaml) must still be present "
                     "at finish — it is removed only AFTER a successful finish")
    # settings mutated: the enablement key must be stripped (when a settings file is cited).
    settings_rel = refs.get("settings")
    if settings_rel is not None:
        spath = _confined_repo_path(repo, settings_rel)
        if spath is None or not os.path.isfile(spath):
            return _fail("uninstall-settings-missing",
                         "refs.settings must be a repo-relative path to the settings file")
        if _plugin_still_enabled(spath):
            return _fail("uninstall-settings-enabled",
                         "the IDC enablement key was NOT stripped from the settings file")
    # the work-product archive must exist (the archive receipt).
    archive_rel = refs.get("archive")
    if not _ne_str(archive_rel):
        return _fail("uninstall-archive", "an applied uninstall requires refs.archive (the work-product archive path)")
    apath = _confined_repo_path(repo, archive_rel)
    if apath is None or not os.path.exists(apath):
        return _fail("uninstall-archive-missing",
                     "refs.archive must reference the work-product archive file, and it must exist")
    return CloseoutResult(True, "ok", "uninstall work independently verified (footprints gone, settings stripped, archive present)", refs)


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


_DOC_ARG_RE = re.compile(r"(?:^|\s)--doc(?:=|\s+)(\S+)")
_UNIT_ARG_RE = re.compile(r"(?:^|\s)--unit(?:=|\s+)(\S+)")


def intake_ref_from_args(command: str, args_text: str):
    """Extract a Think run's intake manifest + selected units from its raw arg text, so intake mode is
    recorded DURABLY on the command record at start (finding 2). Intake mode is stamped IF AND ONLY IF
    the invocation binds a manifest per the brief's argument contract — BOTH `--doc <manifest>` AND a
    NON-EMPTY `--unit <ids>` (round-2 F3-r2). A plain anchor-doc Think (`--doc <anchor>` with no
    `--unit`) is an ordinary, non-intake run and MUST NOT be intake-stamped — stamping it would leave
    an empty selection that the closeout's coverage check rejects, so an honest anchor-doc Think could
    never close. Every other command / arg shape yields (None, None). Storing this on the record (not
    inferring it from caller-supplied finish input) is what stops an intake-mode run from dropping
    units by simply omitting the intake fields at finish."""
    if command != "think" or not args_text:
        return None, None
    doc = _DOC_ARG_RE.search(args_text)
    unit = _UNIT_ARG_RE.search(args_text)
    if not doc or not unit:
        return None, None
    units = [u for u in unit.group(1).split(",") if u]
    if not units:  # `--unit` present but empty/comma-only is not a real intake selection
        return None, None
    return doc.group(1), units


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

    # (5) command-specific evidence. blocked_external is uniform across every command (with a drain
    # blocker additionally re-derived from this session's persisted verdict).
    if status == "blocked_external":
        result = _check_blocker(refs, repo or "", session or "")
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
    PERSISTED, `{}` outside a governed repo, or None when the ledger write FAILED (Fix 2).

    A Think run started with `--doc/--unit` durably stamps its intake manifest + selected units on the
    record (finding 2), so the Think closeout enforces exact-once coverage from the RECORD on every
    path — a finish that omits the intake fields cannot make an intake-mode run look non-intake."""
    intake_manifest, intake_units = intake_ref_from_args(command, args_text or "")
    return idc_ledger.command_start(
        cwd, session_id, command, plugin_version, args_digest(args_text or ""), source or "",
        intake_manifest=intake_manifest, intake_units=intake_units)


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
    # A REAL, non-empty session identity is required (finding 5). Codex/Pi fire no Claude
    # UserPromptExpansion, so a bare `$CLAUDE_CODE_SESSION_ID` can be empty; refuse it here with a
    # precise message rather than opening an anonymous obligation that another session-less run could
    # collide with on (session="", command).
    if not (args.session or "").strip():
        print("idc-command-contract: refusing to open a command record without a session identity "
              "(the runtime must supply a real, non-empty --session — Codex: its thread/run label; "
              "Pi: the resident's idc-<role> id).", file=sys.stderr)
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
    if not (args.session or "").strip():
        print("idc-command-contract: refusing to finish a command record without a session identity "
              "(a blank --session could close another anonymous session's record).", file=sys.stderr)
        return 2
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
