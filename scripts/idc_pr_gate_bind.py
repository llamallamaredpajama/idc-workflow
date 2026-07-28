#!/usr/bin/env python3
"""Bind a Think PR and its requirements-change gate with reciprocal, read-back-verified markers.

The PR body names the gate number; the gate body names the PR number. Preflight validates both
bodies before the first edit, so a mismatch or duplicate is always write-free. A partially landed
correct binding is safe to rerun and writes only the missing side.
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from idc_board_lint import REQUIREMENTS_GATE_PREFIX, is_requirements_gate_title  # noqa: E402
from idc_gate_proof import GATE_PR_MARKER_RE, format_gate_pr_marker  # noqa: E402

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

MARKER = GATE_PR_MARKER_RE


class BindError(Exception):
    """A validation, GitHub read/write, or readback failure."""


def _positive_int(value):
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a positive integer")
    if number <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return number


def _gh_json(args, repo):
    try:
        proc = subprocess.run(["gh"] + list(args), cwd=repo, capture_output=True, text=True,
                              timeout=30)
    except (OSError, subprocess.SubprocessError) as exc:
        raise BindError(f"could not run gh: {exc}")
    if proc.returncode != 0:
        detail = CS.scrub(proc.stderr or proc.stdout or "unknown gh failure").strip()[:300]
        raise BindError(f"gh {' '.join(args[:2])} failed: {detail}")
    if args[1] == "edit":
        return {}
    try:
        value = json.loads(proc.stdout)
    except (TypeError, json.JSONDecodeError) as exc:
        raise BindError(f"gh {' '.join(args[:2])} returned malformed JSON: {exc}")
    if not isinstance(value, dict):
        raise BindError(f"gh {' '.join(args[:2])} returned a non-object JSON value")
    return value


def _read(repo, pr, gate):
    pr_info = _gh_json(["pr", "view", str(pr), "--json", "body"], repo)
    gate_info = _gh_json(["issue", "view", str(gate), "--json", "title,body"], repo)
    pr_body = pr_info.get("body")
    gate_body = gate_info.get("body")
    title = gate_info.get("title")
    if not isinstance(pr_body, str):
        raise BindError(f"PR #{pr} read did not return a text body")
    if not isinstance(gate_body, str) or not isinstance(title, str):
        raise BindError(f"gate #{gate} read did not return a text title and body")
    return pr_body, title, gate_body


def _marker_state(body, expected, surface):
    values = [int(v) for v in MARKER.findall(body)]
    if len(values) > 1:
        raise BindError(f"{surface} carries {len(values)} idc-gate-pr markers; exactly one is allowed")
    if values and values[0] != int(expected):
        raise BindError(f"{surface} is already bound to #{values[0]}, not #{int(expected)}; refusing to rebind")
    return bool(values)


def _append_marker(body, number):
    marker = format_gate_pr_marker(number)
    return body.rstrip() + ("\n\n" if body.rstrip() else "") + marker


def _verify_body(repo, kind, number, expected_body):
    if kind == "pr":
        data = _gh_json(["pr", "view", str(number), "--json", "body"], repo)
    else:
        data = _gh_json(["issue", "view", str(number), "--json", "body"], repo)
    actual = data.get("body")
    if actual != expected_body:
        raise BindError(f"{kind.upper()} #{number} marker write failed readback; stop and rerun safely")


def validate_live_binding(repo, pr, gate, require_requirements_gate=True):
    """The live reciprocal PR↔gate proof the terminal path trusts.

    Reads both bodies fresh and requires EXACT reciprocal markers. By default this is the
    requirements-gate contract the binder itself owns; callers that already proved the gate kind (the
    terminal github dispose path) may set `require_requirements_gate=False` and reuse only the live
    reciprocal-marker proof.
    """
    repo = os.path.abspath(repo)
    pr, gate = _positive_int(pr), _positive_int(gate)
    pr_body, title, gate_body = _read(repo, pr, gate)
    if require_requirements_gate and not is_requirements_gate_title(title):
        raise BindError(f"gate #{gate} is not a {REQUIREMENTS_GATE_PREFIX!r} gate (title: {title!r}); "
                        "this binder is requirements-change-only")
    pr_bound = _marker_state(pr_body, gate, f"PR #{pr} body")
    gate_bound = _marker_state(gate_body, pr, f"gate #{gate} body")
    if not pr_bound:
        raise BindError(f"PR #{pr} body does not reciprocally bind gate #{gate}")
    if not gate_bound:
        raise BindError(f"gate #{gate} body does not bind PR #{pr}")
    return {"pr": pr, "gate": gate, "title": title}


def bind(repo, pr, gate):
    """Validate and apply the reciprocal binding; return the stable result object."""
    repo = os.path.abspath(repo)
    pr, gate = _positive_int(pr), _positive_int(gate)
    pr_body, title, gate_body = _read(repo, pr, gate)
    if not is_requirements_gate_title(title):
        raise BindError(f"gate #{gate} is not a {REQUIREMENTS_GATE_PREFIX!r} gate (title: {title!r}); "
                        "this binder is requirements-change-only")

    pr_bound = _marker_state(pr_body, gate, f"PR #{pr} body")
    gate_bound = _marker_state(gate_body, pr, f"gate #{gate} body")
    if pr_bound and gate_bound:
        return {"action": "skipped-existing", "pr": pr, "gate": gate}

    wrote = []
    if not pr_bound:
        desired = _append_marker(pr_body, gate)
        _gh_json(["pr", "edit", str(pr), "--body", desired], repo)
        _verify_body(repo, "pr", pr, desired)
        wrote.append("pr")
    if not gate_bound:
        desired = _append_marker(gate_body, pr)
        _gh_json(["issue", "edit", str(gate), "--body", desired], repo)
        _verify_body(repo, "gate", gate, desired)
        wrote.append("gate")
    validate_live_binding(repo, pr, gate)
    return {"action": "bound", "pr": pr, "gate": gate, "written": wrote}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Bind a Think PR and requirements gate reciprocally")
    parser.add_argument("--repo", required=True, help="local governed repository root")
    parser.add_argument("--pr", required=True, type=_positive_int, help="Think PR number")
    parser.add_argument("--gate", required=True, type=_positive_int, help="requirements gate issue number")
    args = parser.parse_args(argv)
    try:
        result = bind(args.repo, args.pr, args.gate)
    except BindError as exc:
        sys.stderr.write(f"idc-pr-gate-bind: {exc}\n")
        return 2
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
