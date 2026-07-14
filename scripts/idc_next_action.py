#!/usr/bin/env python3
"""Derive IDC's one truthful next command from durable intake and tracker state.

The oracle is read-only. It validates every canonical intake manifest in
``docs/workflow/intakes/``, reads the active tracker through the same filesystem/GitHub loaders and
build predicate as Autorun, then applies one fixed precedence table. Foreign Markdown by itself is
never consulted and therefore can never become Build input.

CLI: ``idc_next_action.py --repo <governed-repo> --json``

Exit 0 means the JSON contains a determinate action, wait, or fixpoint. Exit 2 means intake or
tracker state was invalid/unreadable. Exit 3 means the shared GitHub reader was rate-limited.
"""

from __future__ import annotations

import argparse
import contextlib
import dataclasses
import io
import json
import os
import re
import sys
from typing import Any


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import idc_autorun_drain as DRAIN  # noqa: E402 — shared tracker readers and build predicate
import idc_board_lint as BOARD_LINT  # noqa: E402 — canonical operator-gate title marker
import idc_gh_board as GH_BOARD  # noqa: E402 — rate-aware repository identity
import idc_intake_manifest as INTAKE  # noqa: E402 — canonical manifest/review validation
import idc_tracker_fs as TRACKER_FS  # noqa: E402 — canonical field domains


MANIFEST_NAME_RE = re.compile(r"^(\d{4}-\d{2}-\d{2}-[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)\.json$")


@dataclasses.dataclass(frozen=True)
class WorkflowState:
    intake_think: tuple[str, ...]
    intake_recirc: tuple[str, ...]
    recirc_tickets: tuple[int, ...]
    considerations: tuple[int, ...]
    eligible_buildables: tuple[int, ...]
    waiting_gates: tuple[int, ...]


@dataclasses.dataclass(frozen=True)
class NextAction:
    verdict: str
    reason_code: str
    command: str | None
    refs: tuple[str, ...]
    counts: dict[str, int]


class _StateError(Exception):
    """A durable input could not be validated without guessing."""

    def __init__(self, reason_code: str, ref: str | None = None):
        super().__init__(reason_code)
        self.reason_code = reason_code
        self.ref = ref


class _RateLimited(Exception):
    """The shared GitHub reader reported its distinct resumable exit state."""


def _repo_relative(repo: str, path: str) -> str:
    return os.path.relpath(path, repo).replace(os.sep, "/")


def _collect_intakes(repo: str) -> tuple[tuple[str, ...], tuple[str, ...]]:
    """Validate canonical manifests and return queued ``manifest#unit`` references.

    Review files and arbitrary JSON inputs are not manifests: only the canonical
    ``<YYYY-MM-DD>-<slug>.json`` names enter the durable read model. Every canonical file is
    validated even if all its units are terminal, so corruption cannot hide behind completion.
    """
    root = os.path.join(repo, "docs", "workflow", "intakes")
    if not os.path.lexists(root):
        return (), ()
    if not os.path.isdir(root):
        raise _StateError("invalid-intake", _repo_relative(repo, root))

    think: list[str] = []
    recirc: list[str] = []
    try:
        names = sorted(os.listdir(root))
    except OSError as exc:
        raise _StateError("invalid-intake", _repo_relative(repo, root)) from exc

    for name in names:
        match = MANIFEST_NAME_RE.fullmatch(name)
        if not match:
            continue
        path = os.path.join(root, name)
        if not os.path.isfile(path):
            raise _StateError("invalid-intake", _repo_relative(repo, path))
        rel = _repo_relative(repo, path)
        try:
            with open(path, encoding="utf-8") as handle:
                manifest = json.load(handle)
            if not isinstance(manifest, dict):
                raise INTAKE.IntakeError("manifest must be a JSON object")
            INTAKE.validate_manifest(manifest)
            if manifest["intake_id"] != match.group(1):
                raise INTAKE.IntakeError("manifest intake_id does not match its canonical filename")
            if manifest["verification"]["status"] != "passed":
                raise INTAKE.IntakeError("manifest has not passed independent review")
            INTAKE._resolve_stamped_review(path, manifest)
        except (OSError, UnicodeError, json.JSONDecodeError,
                INTAKE.IntakeError, KeyError, TypeError) as exc:
            raise _StateError("invalid-intake", rel) from exc

        for unit in manifest["units"]:
            if unit["disposition"]["state"] != "queued":
                continue
            ref = f"{rel}#{unit['id']}"
            if unit["class"] == "new_requirement" and unit["route"] == "think":
                think.append(ref)
            elif unit["class"] in ("admitted_unplanned", "discovered_drift") \
                    and unit["route"] == "recirculate":
                recirc.append(ref)
            else:
                # A reviewed queued unit with no representable IDC entry point is not a fixpoint.
                # Fail closed rather than silently dropping durable intake work.
                raise _StateError("invalid-intake", ref)
    return tuple(sorted(think)), tuple(sorted(recirc))


def _read_tracker_config(repo: str) -> tuple[str, str]:
    """Return ``(backend, project_number)`` from the repo's constrained tracker config.

    This only selects the existing backend reader; it does not parse board output. Missing config
    retains IDC's existing filesystem default for older governed repos.
    """
    path = os.path.join(repo, "docs", "workflow", "tracker-config.yaml")
    if not os.path.isfile(path):
        return "filesystem", ""
    backend = ""
    project = ""
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                match = re.match(r"^\s*backend:\s*['\"]?([A-Za-z0-9_-]+)", line)
                if match:
                    backend = match.group(1).strip()
                match = re.match(r'^\s*project_number:\s*"?([^"#\n]*)"?', line)
                if match:
                    project = match.group(1).strip()
    except OSError as exc:
        raise _StateError("invalid-tracker", _repo_relative(repo, path)) from exc
    return backend or "filesystem", project


def _validate_issues(issues: Any) -> list[dict[str, Any]]:
    """Guard the fields the oracle classifies after the shared loader has read them."""
    if not isinstance(issues, list):
        raise _StateError("invalid-tracker")
    seen: set[int] = set()
    for issue in issues:
        if not isinstance(issue, dict) or not isinstance(issue.get("number"), int):
            raise _StateError("invalid-tracker")
        number = issue["number"]
        if number in seen:
            raise _StateError("invalid-tracker", f"#{number}")
        seen.add(number)
        if issue.get("status") not in TRACKER_FS.STATUSES:
            raise _StateError("invalid-tracker", f"#{number}")
        if issue.get("stage") not in ("", None, *TRACKER_FS.STAGES):
            raise _StateError("invalid-tracker", f"#{number}")
        if not isinstance(issue.get("title", ""), str):
            raise _StateError("invalid-tracker", f"#{number}")
        blocked_by = issue.get("blocked_by", [])
        if not isinstance(blocked_by, list) or any(not isinstance(value, int) for value in blocked_by):
            raise _StateError("invalid-tracker", f"#{number}")
    return issues


def _load_tracker_issues(repo: str) -> list[dict[str, Any]]:
    backend, project = _read_tracker_config(repo)
    if backend == "filesystem":
        tracker = os.path.join(repo, "TRACKER.md")
        try:
            issues = DRAIN.load_filesystem(tracker)
        except SystemExit as exc:
            raise _StateError("invalid-tracker", _repo_relative(repo, tracker)) from exc
        return _validate_issues(issues)

    if backend != "github" or not project.isdigit() or int(project) <= 0:
        raise _StateError("invalid-tracker", "docs/workflow/tracker-config.yaml")

    try:
        owner = GH_BOARD._current_repository(repo).split("/", 1)[0]
        # The shared drain loader owns pagination, board normalization, dependency reads, and their
        # rate-limit/hard-error exit semantics. Suppress its drain-specific stdout token so this
        # oracle's stdout remains one JSON document. ``root=None`` prevents verdict persistence: this
        # command is an observer, not an Autorun drain pass.
        with contextlib.redirect_stdout(io.StringIO()):
            issues, unverified = DRAIN.load_github(owner, int(project), repo, root=None, sid=None)
    except GH_BOARD.RateLimitError as exc:
        raise _RateLimited() from exc
    except SystemExit as exc:
        if exc.code == 3:
            raise _RateLimited() from exc
        raise _StateError("invalid-tracker", f"github-project-{project}") from exc
    except (GH_BOARD.BoardReadError, OSError, ValueError) as exc:
        raise _StateError("invalid-tracker", f"github-project-{project}") from exc

    issues = _validate_issues(issues)
    if unverified and not DRAIN.compute_eligible(issues):
        # Preserve the drain's aggregate blind-read guard: no ready item plus an unverifiable build
        # candidate is unknown state, never a false fixpoint.
        raise _StateError("invalid-tracker", f"github-project-{project}")
    return issues


def _collect_workflow_state(repo: str) -> WorkflowState:
    intake_think, intake_recirc = _collect_intakes(repo)
    issues = _load_tracker_issues(repo)
    recirc = tuple(sorted(
        issue["number"] for issue in issues
        if issue.get("stage") == "Recirculation" and issue.get("status") == "Todo"
    ))
    considerations = tuple(sorted(
        issue["number"] for issue in issues
        if issue.get("stage") == "Consideration" and issue.get("status") == "Todo"
    ))
    eligible = tuple(DRAIN.compute_eligible(issues))
    gates = tuple(sorted(
        issue["number"] for issue in issues
        if issue.get("status") != "Done"
        and issue.get("title", "").strip().startswith(BOARD_LINT.OPERATOR_GATE_PREFIX)
    ))
    return WorkflowState(
        intake_think=intake_think,
        intake_recirc=intake_recirc,
        recirc_tickets=recirc,
        considerations=considerations,
        eligible_buildables=eligible,
        waiting_gates=gates,
    )


def _counts(state: WorkflowState) -> dict[str, int]:
    return {
        "intake_think": len(state.intake_think),
        "intake_recirc": len(state.intake_recirc),
        "recirc_tickets": len(state.recirc_tickets),
        "considerations": len(state.considerations),
        "eligible_buildables": len(state.eligible_buildables),
        "waiting_gates": len(state.waiting_gates),
    }


def _action(verdict: str, reason: str, command: str | None, refs: tuple[str, ...],
            counts: dict[str, int]) -> NextAction:
    return NextAction(verdict=verdict, reason_code=reason, command=command, refs=refs, counts=counts)


def _zero_counts() -> dict[str, int]:
    return {
        "intake_think": 0,
        "intake_recirc": 0,
        "recirc_tickets": 0,
        "considerations": 0,
        "eligible_buildables": 0,
        "waiting_gates": 0,
    }


def decide(repo: str) -> NextAction:
    """Return the one deterministic IDC action, wait, fixpoint, or invalid-state verdict."""
    repo = os.path.realpath(os.path.abspath(repo))
    try:
        state = _collect_workflow_state(repo)
    except _RateLimited:
        return _action("blocked_external", "rate-limited", None, (), _zero_counts())
    except _StateError as exc:
        refs = (exc.ref,) if exc.ref else ()
        return _action("invalid", exc.reason_code, None, refs, _zero_counts())

    counts = _counts(state)

    # Think is the gate at the top of the pipe. Autorun must never bury a new requirement.
    if state.intake_think:
        manifest, unit = state.intake_think[0].rsplit("#", 1)
        return _action(
            "action", "intake-needs-think", f"/idc:think --doc {manifest} --unit {unit}",
            state.intake_think, counts,
        )

    recirc_actionable = bool(state.intake_recirc or state.recirc_tickets)
    plan_actionable = bool(state.considerations)
    build_actionable = bool(state.eligible_buildables)
    if sum((recirc_actionable, plan_actionable, build_actionable)) >= 2:
        refs = tuple([
            *state.intake_recirc,
            *(f"#{number}" for number in state.recirc_tickets),
            *(f"#{number}" for number in state.considerations),
            *(f"#{number}" for number in state.eligible_buildables),
        ])
        return _action("action", "multi-lane-actionable", "/idc:autorun", refs, counts)

    if state.intake_recirc:
        return _action(
            "action", "intake-needs-recirculation",
            f"/idc:recirculate {state.intake_recirc[0]}", state.intake_recirc, counts,
        )
    if state.recirc_tickets:
        return _action(
            "action", "recirculation-inbox", "/idc:recirculate",
            tuple(f"#{number}" for number in state.recirc_tickets), counts,
        )
    if state.considerations:
        return _action(
            "action", "admitted-consideration", "/idc:plan",
            tuple(f"#{number}" for number in state.considerations), counts,
        )
    if state.eligible_buildables:
        return _action(
            "action", "eligible-buildable", "/idc:build",
            tuple(f"#{number}" for number in state.eligible_buildables), counts,
        )
    if state.waiting_gates:
        return _action(
            "waiting", "waiting-human-gate", None,
            tuple(f"#{number}" for number in state.waiting_gates), counts,
        )
    return _action("no_action", "fixpoint", None, (), counts)


def _exit_code(action: NextAction) -> int:
    if action.reason_code == "rate-limited":
        return 3
    if action.verdict == "invalid":
        return 2
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="governed repository root")
    parser.add_argument("--json", action="store_true", help="emit one machine-readable JSON object")
    args = parser.parse_args(argv)
    action = decide(args.repo)
    if args.json:
        print(json.dumps(dataclasses.asdict(action), sort_keys=True))
    elif action.command:
        print(f"next-action: {action.command} ({action.reason_code})")
    else:
        print(f"next-action: {action.reason_code}")
    return _exit_code(action)


if __name__ == "__main__":
    raise SystemExit(main())
