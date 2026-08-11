#!/usr/bin/env python3
"""Resolve a plain-language `/idc:ask` request without mutating anything.

CLI: ``idc_ask_resolve.py --repo <repo> --text <free text> --json``.
Exit 0 means a route or advisory was determined. Exit 2 means ``--repo`` is
not a readable directory. The resolver never writes files or tracker state.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import sys
from typing import Any


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import idc_next_action as NEXT  # noqa: E402 — the shared read-only oracle
import idc_pause_state as PAUSE  # noqa: E402 — the one durable confirmed-pause reader


ROUTABLE = frozenset({
    "pause", "resume", "doctor", "janitor",
    "think", "intake", "plan", "build", "recirculate", "autorun",
})

# NEVER routable — these change the installation and must be typed deliberately.
LIFECYCLE_ONLY = frozenset({"init", "update", "uninstall"})

LIFECYCLE_CUES = (
    "install idc", "uninstall", "remove idc", "update idc", "upgrade idc",
    "set up idc", "setup idc", "scaffold", "reinstall",
)

KEYWORDS = {
    "pause": ("stop", "stopping", "pause", "halt", "wrap up", "wrapping up",
              "done for now", "knock off", "call it a night", "call it a day",
              "stop work", "stop here", "shut down for now"),
    "resume": ("resume", "pick up", "picking up", "carry on",
               "left off",
               "pick it back up", "start again"),
    "doctor": ("broken", "health", "healthy", "diagnose", "diagnostic",
               "something wrong", "is anything wrong", "sanity check",
               "check the install", "misconfigured"),
    "janitor": ("tidy", "clean up", "cleanup", "reconcile", "stale",
                "housekeeping", "out of sync", "drift"),
}


def _normalized(text: str) -> str:
    """Lowercase words separated by one space, with punctuation as a boundary."""
    return " " + " ".join(re.sub(r"[^a-z0-9]+", " ", text.lower()).split()) + " "


def _matches(normalized: str, cue: str) -> bool:
    return " " + cue + " " in normalized


def _negated(normalized: str, cue: str) -> bool:
    """Whether ``cue`` is immediately rejected instead of requested.

    `_normalized` deliberately turns punctuation into spaces, so both ``don't resume``
    and ``dont resume`` arrive as token sequences we can inspect without guessing at
    word boundaries. A negative request must never become an authorization-bearing
    route to the command the operator explicitly ruled out.
    """
    return any(
        " " + prefix + " " + cue + " " in normalized
        for prefix in ("not", "never", "no", "dont", "don t")
    )


def _result(verdict: str, command: str | None, command_args: str, reason_code: str,
            matched: list[str] | None = None, oracle: dict[str, Any] | None = None) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "verdict": verdict,
        "command": command,
        "command_args": command_args,
        "reason_code": reason_code,
        "matched": matched or [],
        "oracle": oracle or {"verdict": None, "reason_code": None, "command": None,
                             "refs": [], "counts": {}},
    }


def resolve_keywords(text: str) -> dict[str, Any]:
    """Resolve installation and housekeeping language without reading a repository."""
    normalized = _normalized(text or "")
    lifecycle = [cue for cue in LIFECYCLE_CUES if _matches(normalized, cue)]
    if lifecycle:
        return _result("advisory", None, "", "lifecycle-command", lifecycle)

    matches: list[tuple[str, str]] = []
    for command, cues in KEYWORDS.items():
        for cue in cues:
            if _matches(normalized, cue) and not _negated(normalized, cue):
                matches.append((command, cue))

    commands = {command for command, _cue in matches}
    if len(commands) > 1:
        return _result("advisory", None, "", "ambiguous", [cue for _command, cue in matches])
    if len(commands) == 1:
        command = next(iter(commands))
        cue = next(cue for candidate, cue in matches if candidate == command)
        if command == "resume":
            # Resume is a state transition, not a synonym for generic continuation. The pure
            # keyword pass cannot prove the repository is paused; `resolve()` performs that live
            # read and otherwise falls through to the ordinary next-action oracle.
            return _result("advisory", None, "", "resume-state-required", [cue])
        if command in ROUTABLE:
            return _result("route", command, "", "keyword-" + command, [cue])
    return _result("advisory", None, "", "no-match")


def _oracle_payload(action: Any) -> dict[str, Any]:
    """Make the NextAction dataclass into the stable resolver response shape."""
    if dataclasses.is_dataclass(action):
        action = dataclasses.asdict(action)
    if not isinstance(action, dict):
        return {"verdict": None, "reason_code": None, "command": None, "refs": [], "counts": {}}
    return {
        "verdict": action.get("verdict"),
        "reason_code": action.get("reason_code"),
        "command": action.get("command"),
        "refs": list(action.get("refs") or []),
        "counts": dict(action.get("counts") or {}),
    }


def _split_command(command: object) -> tuple[str | None, str]:
    if not isinstance(command, str) or not command.startswith("/idc:"):
        return None, ""
    bare = command[len("/idc:"):]
    name, separator, args = bare.partition(" ")
    return name or None, args if separator else ""


def resolve(repo: str, text: str) -> dict[str, Any]:
    """Return the one safe route, or an advisory answer, for ``text`` in ``repo``."""
    keyword_result = resolve_keywords(text)
    if keyword_result["reason_code"] == "resume-state-required":
        if PAUSE.is_paused(repo):
            return _result(
                "route", "resume", "", "confirmed-pause", keyword_result.get("matched")
            )
        # Not paused: "resume" / "pick up" means "what should happen next", and only the live
        # workflow oracle can answer that without inventing a state transition.
    elif keyword_result["reason_code"] != "no-match":
        return keyword_result

    try:
        action = NEXT.decide(repo)
    except Exception:  # noqa: BLE001 — the entry gate must stay available
        return _result("advisory", None, "", "oracle-invalid")
    oracle = _oracle_payload(action)
    verdict = oracle["verdict"]
    if verdict == "action":
        command, command_args = _split_command(oracle["command"])
        if command in ROUTABLE:
            return _result("route", command, command_args, "oracle-action", oracle=oracle)
        return _result("advisory", None, "", "no-match", oracle=oracle)
    if verdict == "waiting":
        return _result("advisory", None, "", "oracle-waiting", oracle=oracle)
    if verdict == "no_action":
        return _result("advisory", None, "", "oracle-fixpoint", oracle=oracle)
    if verdict == "blocked_external":
        return _result("advisory", None, "", "oracle-rate-limited", oracle=oracle)
    return _result("advisory", None, "", "oracle-invalid", oracle=oracle)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, help="repository to inspect")
    parser.add_argument("--text", required=True, help="operator's plain-language request")
    parser.add_argument("--json", action="store_true", help="emit one machine-readable result")
    args = parser.parse_args(argv)
    if not os.path.isdir(args.repo) or not os.access(args.repo, os.R_OK | os.X_OK):
        print("idc-ask-resolve: --repo must be a readable directory", file=sys.stderr)
        return 2
    result = resolve(args.repo, args.text)
    if args.json:
        print(json.dumps(result, sort_keys=True))
    else:
        print(result["command"] or result["reason_code"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
